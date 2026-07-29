#!/usr/bin/env bash
# Preflight checks for "PostgreSQL EBS Volume Right-Sizing via Same-Host Standby
# Switchover". Run locally on each node (as the postgres OS user, or any user
# with sudo) with --role primary or --role replica; a human runs it on all
# three nodes and confirms every result before scheduling the window.
#
# Connects via standard libpq env vars (PGHOST, PGPORT, PGUSER, PGPASSWORD,
# PGDATABASE) -- defaults to local socket/peer auth if unset.

set -u

ROLE=""
NEW_VOLUME_SIZE_GB=""
FAIL=0
WARN=0
RESULTS=()

usage() {
  echo "Usage: $0 --role primary|replica [--new-volume-size-gb N]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --new-volume-size-gb) NEW_VOLUME_SIZE_GB="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done
[[ "$ROLE" == "primary" || "$ROLE" == "replica" ]] || usage

query() { psql -X -q -t -A -c "$1" 2>&1; }

record() {
  local status="$1" name="$2" detail="$3" mark
  case "$status" in
    PASS) mark="[PASS]" ;;
    WARN) mark="[WARN]"; WARN=$((WARN + 1)) ;;
    FAIL) mark="[FAIL]"; FAIL=$((FAIL + 1)) ;;
  esac
  RESULTS+=("$mark $name -- $detail")
}

# --- C0: can we even connect? bail early with a clear NO-GO if not ---
probe=$(query "SELECT 1;")
if [[ "$probe" != "1" ]]; then
  echo "[FAIL] connectivity -- could not connect via psql (PGHOST/PGPORT/PGUSER/PGDATABASE): $probe"
  echo
  echo "NO-GO -- cannot run further checks without a database connection"
  exit 1
fi

# --- C1: PostgreSQL version >= 13 ---
ver_num=$(query "SHOW server_version_num;")
if [[ "$ver_num" =~ ^[0-9]+$ ]] && [[ "$ver_num" -ge 130000 ]]; then
  record PASS "pg_version" "server_version_num=$ver_num (>= 13)"
else
  record FAIL "pg_version" "could not confirm PG >= 13 (got: $ver_num)"
fi

# --- C7: superuser + OS access ---
if [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null; then
  record PASS "os_privileged_access" "running as root or passwordless sudo confirmed"
else
  record FAIL "os_privileged_access" "not root and passwordless sudo not available"
fi

current_user=$(query "SELECT current_user;")
is_super=$(query "SELECT rolsuper FROM pg_roles WHERE rolname = current_user;")
can_replicate=$(query "SELECT rolreplication FROM pg_roles WHERE rolname = current_user;")

if [[ "$can_replicate" == "t" || "$is_super" == "t" ]]; then
  record PASS "pg_replication_capable" "connected role '$current_user' can run pg_basebackup / create replication slots (rolreplication=$can_replicate, rolsuper=$is_super)"
else
  record FAIL "pg_replication_capable" "connected role '$current_user' has neither REPLICATION nor superuser -- cannot run pg_basebackup or create replication slots"
fi

if [[ "$is_super" == "t" ]]; then
  record PASS "pg_superuser_for_altersystem" "connected role '$current_user' is superuser -- ALTER SYSTEM (phase 3.2/4) will work"
else
  record WARN "pg_superuser_for_altersystem" "connected role '$current_user' is not superuser -- ALTER SYSTEM will fail with 'permission denied to set parameter'. On Supabase-hosted nodes, connect locally (via SSH) as supabase_admin instead of the network-facing application role for phase 3.2/4 steps; pg_reload_conf() is available to non-superusers here but ALTER SYSTEM is not"
fi

if [[ "$ROLE" == "primary" ]]; then
  # --- C3: no logical replication slots (physical basebackup can't carry these) ---
  logical_slots=$(query "SELECT count(*) FROM pg_replication_slots WHERE slot_type = 'logical';")
  if [[ "$logical_slots" == "0" ]]; then
    record PASS "no_logical_slots" "0 logical replication slots present"
  else
    record FAIL "no_logical_slots" "$logical_slots logical replication slot(s) found -- STOP, this is a separate workstream (no basebackup carry-over, no sync pre-PG17)"
  fi

  # --- C4: pause-capable proxy in front of the primary ---
  if systemctl is-active --quiet pgbouncer 2>/dev/null || pgrep -x pgbouncer >/dev/null 2>&1; then
    record PASS "pause_capable_proxy" "pgbouncer detected on this host -- still MANUALLY CONFIRM all application writes actually route through it, not direct to :5432"
  else
    record WARN "pause_capable_proxy" "no local pgbouncer/pgpool detected -- confirm one exists elsewhere, or deploy one before scheduling"
  fi

  # --- C5: new volume sizing ---
  db_size_bytes=$(query "SELECT sum(pg_database_size(datname)) FROM pg_database;")
  max_wal_size=$(query "SHOW max_wal_size;")
  data_dir=$(query "SHOW data_directory;")
  df_line=$(df -B1 "$data_dir" 2>/dev/null | tail -1)
  provisioned_bytes=$(echo "$df_line" | awk '{print $2}')
  if [[ "$db_size_bytes" =~ ^[0-9]+$ && "$provisioned_bytes" =~ ^[0-9]+$ ]]; then
    db_size_gb=$((db_size_bytes / 1073741824))
    provisioned_gb=$((provisioned_bytes / 1073741824))
    detail="current DB size ~${db_size_gb}GB, current volume ~${provisioned_gb}GB provisioned, max_wal_size=${max_wal_size}"
    if [[ -n "$NEW_VOLUME_SIZE_GB" ]]; then
      recommended_gb=$((db_size_gb + (db_size_gb * 40 / 100) + 5))
      if [[ "$NEW_VOLUME_SIZE_GB" -ge "$recommended_gb" ]]; then
        record PASS "volume_sizing" "$detail; requested new size ${NEW_VOLUME_SIZE_GB}GB >= rule-of-thumb minimum ${recommended_gb}GB"
      else
        record FAIL "volume_sizing" "$detail; requested new size ${NEW_VOLUME_SIZE_GB}GB < rule-of-thumb minimum ${recommended_gb}GB (db size + WAL headroom + 30-50% growth)"
      fi
    else
      record WARN "volume_sizing" "$detail; pass --new-volume-size-gb to validate against the rule-of-thumb minimum"
    fi
  else
    record WARN "volume_sizing" "could not compute db size or disk usage automatically"
  fi

  # --- C6: instance headroom for a second postmaster during phases 1-4 ---
  mem_avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
  shared_buffers=$(query "SHOW shared_buffers;")
  if [[ "$mem_avail_kb" =~ ^[0-9]+$ ]]; then
    mem_avail_mb=$((mem_avail_kb / 1024))
    if [[ "$mem_avail_mb" -gt 512 ]]; then
      record PASS "instance_headroom" "MemAvailable=${mem_avail_mb}MB, primary shared_buffers=${shared_buffers} -- budget the standby's shared_buffers on top of this"
    else
      record WARN "instance_headroom" "MemAvailable=${mem_avail_mb}MB is low -- set a lower shared_buffers on the standby for phases 1-4"
    fi
  else
    record WARN "instance_headroom" "could not read /proc/meminfo"
  fi

  # --- C8: backup exists and is restorable ---
  archive_mode=$(query "SHOW archive_mode;")
  archive_command=$(query "SHOW archive_command;")
  if [[ "$archive_mode" == "on" && -n "$archive_command" && "$archive_command" != "(disabled)" ]]; then
    record WARN "backup_restorable" "archive_mode=on, archive_command set -- automated check stops here; MANUALLY CONFIRM the most recent base backup + WAL archive actually restores before scheduling"
  else
    record FAIL "backup_restorable" "archive_mode=$archive_mode, archive_command='$archive_command' -- WAL archiving not confirmed active"
  fi
fi

if [[ "$ROLE" == "replica" ]]; then
  # --- C2: recovery_target_timeline = latest (so the replica follows promotion) ---
  timeline=$(query "SHOW recovery_target_timeline;")
  if [[ "$timeline" == "latest" ]]; then
    record PASS "recovery_target_timeline" "recovery_target_timeline=latest"
  else
    record FAIL "recovery_target_timeline" "recovery_target_timeline='$timeline' (expected 'latest') -- this replica will not follow the timeline switch automatically"
  fi

  in_recovery=$(query "SELECT pg_is_in_recovery();")
  if [[ "$in_recovery" == "t" ]]; then
    record PASS "is_replica" "pg_is_in_recovery() = t"
  else
    record FAIL "is_replica" "pg_is_in_recovery() = $in_recovery -- this node is not a replica"
  fi
fi

echo "=== Preflight results (role: $ROLE) ==="
for r in "${RESULTS[@]}"; do
  echo "$r"
done
echo

if [[ "$FAIL" -gt 0 ]]; then
  echo "NO-GO -- $FAIL check(s) failed, $WARN warning(s)"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "GO WITH WARNINGS -- $WARN check(s) need manual confirmation"
  exit 0
else
  echo "GO -- all automated checks passed"
  exit 0
fi
