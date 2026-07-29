#!/usr/bin/env bash
# Phase 4 of the EBS right-sizing runbook: the cutover. Supervised and
# step-confirming by design -- a human confirms each irreversible step by
# pressing Enter. Run locally on the primary as a user with sudo.
#
# Fixes baked in from rehearsal:
#   - fencing the old primary with `systemctl stop` is NOT enough: a Salt
#     reconciliation agent (supabase-admin-agent_salt.timer, ~5min cadence)
#     treats a stopped-but-not-masked unit as drift and restarts it. Must
#     mask, not just stop.
#   - pg_ctl promote is broken on this Nix-based image (exec-path resolution
#     picks a sharedir that doesn't exist). Use SELECT pg_promote() instead.
#   - raise PgBouncer's query_wait_timeout BEFORE pausing -- the default
#     120s is a hard ceiling on how long the whole PAUSE-to-RESUME window
#     may take, not just a nice-to-have target.
#   - PgBouncer is not the only consumer: PostgREST, GoTrue, and
#     postgres_exporter all connect directly to the primary's port (bypassing
#     PgBouncer entirely), and Supavisor (external, shared, not on this box)
#     does too. All of them are hardcoded to the ORIGINAL port. Phase 4.7
#     below moves the new primary back to that port specifically so these
#     self-heal via ordinary client reconnect logic, instead of needing each
#     one individually reconfigured (impossible for Supavisor from here).
set -euo pipefail

STANDBY_PORT="${1:?Usage: $0 <standby-port> <pgbouncer-admin-password>}"
PGB_ADMIN_PW="${2:?}"
PRIMARY_PORT=5432
PGBOUNCER_PORT=6543

confirm() {
  read -r -p "$1 [press Enter to proceed, Ctrl-C to abort] "
}

echo "=== Pre-flight ==="
psql -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d postgres -c \
  "SELECT application_name, state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;"
psql -h 127.0.0.1 -p "$STANDBY_PORT" -U postgres -d postgres -c \
  "SELECT application_name, state FROM pg_stat_replication;"
confirm "Lag looks near-zero and both replicas are streaming from the standby?"

echo "=== Raise query_wait_timeout before pausing (default 120s is a hard ceiling, not a target) ==="
sudo sed -i 's/^;query_wait_timeout = 120/query_wait_timeout = 300/' /etc/pgbouncer/pgbouncer.ini
PGPASSWORD="$PGB_ADMIN_PW" psql -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U pgbouncer pgbouncer -c "RELOAD;"
confirm "query_wait_timeout raised. Ready to PAUSE PgBouncer?"

echo "=== 4.1 PAUSE ==="
date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
PGPASSWORD="$PGB_ADMIN_PW" psql -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U pgbouncer pgbouncer -c "PAUSE;"

echo "=== 4.2 Checkpoint + verify LSN match (as supabase_admin: CHECKPOINT needs real superuser) ==="
export PGOPTIONS="-c pg_stat_statements.track=none"
psql -U supabase_admin -h localhost -p "$PRIMARY_PORT" -d postgres -c "CHECKPOINT;"
unset PGOPTIONS
PRIMARY_LSN=$(psql -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d postgres -t -A -c "SELECT pg_current_wal_lsn();")
STANDBY_LSN=$(psql -h 127.0.0.1 -p "$STANDBY_PORT" -U postgres -d postgres -t -A -c "SELECT pg_last_wal_replay_lsn();")
echo "primary: $PRIMARY_LSN   standby: $STANDBY_LSN"
if [[ "$PRIMARY_LSN" != "$STANDBY_LSN" ]]; then
  echo "LSN MISMATCH -- do not proceed. Investigate before continuing (or RESUME to abort the cutover)."
  exit 1
fi
confirm "LSNs match. Ready to fence the old primary (irreversible from here)?"

echo "=== 4.3 Fence old primary -- mask, not just stop (Salt will resurrect a bare stop within ~5min) ==="
date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
sudo systemctl stop postgresql
sudo systemctl mask postgresql || true
if ! sudo systemctl is-enabled postgresql 2>&1 | grep -q masked; then
  sudo cp /etc/systemd/system/postgresql.service /etc/systemd/system/postgresql.service.rehearsal-backup
  sudo rm /etc/systemd/system/postgresql.service
  sudo ln -s /dev/null /etc/systemd/system/postgresql.service
  sudo systemctl daemon-reload
fi
date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
confirm "Old primary fenced and masked. Ready to promote the standby (irreversible)?"

echo "=== 4.4 Promote (SELECT pg_promote(), not pg_ctl promote -- broken on this image) ==="
date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
export PGOPTIONS="-c pg_stat_statements.track=none"
psql -U supabase_admin -h localhost -p "$STANDBY_PORT" -d postgres -c "SELECT pg_promote();"
unset PGOPTIONS
date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
psql -h 127.0.0.1 -p "$STANDBY_PORT" -U postgres -d postgres -c "SELECT pg_is_in_recovery();"
confirm "Promotion confirmed (pg_is_in_recovery = f). Ready to repoint PgBouncer?"

echo "=== 4.5 Repoint PgBouncer, RECONNECT to drop pooled connections to the dead old primary ==="
sudo sed -i "s|^\* = host=localhost auth_user=pgbouncer|* = host=localhost port=$STANDBY_PORT auth_user=pgbouncer|" /etc/pgbouncer/pgbouncer.ini
PGPASSWORD="$PGB_ADMIN_PW" psql -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U pgbouncer pgbouncer -c "RELOAD;"
PGPASSWORD="$PGB_ADMIN_PW" psql -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U pgbouncer pgbouncer -c "RECONNECT;"
confirm "PgBouncer repointed. Ready to RESUME?"

echo "=== 4.6 RESUME ==="
PGPASSWORD="$PGB_ADMIN_PW" psql -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U pgbouncer pgbouncer -c "RESUME;"
date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"

echo "=== Post-cutover verification ==="
psql -h 127.0.0.1 -p "$STANDBY_PORT" -U postgres -d postgres -c \
  "SELECT timeline_id FROM pg_control_checkpoint();"
psql -h 127.0.0.1 -p "$STANDBY_PORT" -U postgres -d postgres -c \
  "SELECT application_name, state, replay_lsn FROM pg_stat_replication;"

confirm "Standby healthy on port $STANDBY_PORT. Ready for Phase 4.7 -- move it back to port $PRIMARY_PORT so PostgREST/GoTrue/postgres_exporter/Supavisor can reconnect without individual reconfiguration?"

echo "=== 4.7 Move new primary back to the original port ==="
echo "This restart must be paused too -- an earlier version of this script restarted"
echo "Postgres here without pausing PgBouncer first, which reintroduced exactly the"
echo "hard client errors (FATAL: server conn crashed) this whole procedure exists to"
echo "avoid. Do not remove this pause."
PGPASSWORD="$PGB_ADMIN_PW" psql -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U pgbouncer pgbouncer -c "PAUSE;"

sudo systemctl stop postgresql-standby
sudo -u postgres bash -c "echo \"port = $PRIMARY_PORT\" >> /pgdata-new/data/postgresql.auto.conf"
sudo systemctl start postgresql-standby
sleep 3
psql -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d postgres -c "SELECT pg_is_in_recovery();"

sudo sed -i "s|^\* = host=localhost port=$STANDBY_PORT auth_user=pgbouncer|* = host=localhost port=$PRIMARY_PORT auth_user=pgbouncer|" /etc/pgbouncer/pgbouncer.ini
PGPASSWORD="$PGB_ADMIN_PW" psql -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U pgbouncer pgbouncer -c "RELOAD;"
PGPASSWORD="$PGB_ADMIN_PW" psql -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U pgbouncer pgbouncer -c "RECONNECT;"
PGPASSWORD="$PGB_ADMIN_PW" psql -h 127.0.0.1 -p "$PGBOUNCER_PORT" -U pgbouncer pgbouncer -c "RESUME;"

echo "=== Verify on-box direct consumers recovered (should be immediate) ==="
curl -s -o /dev/null -w "postgrest=%{http_code}\n" http://localhost:3000/ || true
curl -s -o /dev/null -w "exporter=%{http_code}\n" http://localhost:9187/metrics || true
echo "Note: Supavisor (external) may take substantially longer to recover than on-box"
echo "consumers -- observed in rehearsal to trip its own auth-failure circuit breaker"
echo "during the port-mismatch window, which then needs its own cooldown independent"
echo "of backend health. This is expected; do not attempt to work around it from here."
echo "Done. Verify application error rates / pgbench error count separately."
