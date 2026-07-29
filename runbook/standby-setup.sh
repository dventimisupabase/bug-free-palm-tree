#!/usr/bin/env bash
# Phases 1-2 of the EBS right-sizing runbook: provision the new volume's
# filesystem and build the standby, with fixes baked in from rehearsal:
#   - pg_hba.conf needs an explicit 'replication' database line (database=all
#     does not cover it)
#   - listen_addresses must be set to '*' before first start (postmaster
#     context GUC -- a reload after the fact is not enough, needs a restart)
#   - the standby must run under systemd, not a bare nohup'd process, or it
#     has no supervision going forward
#   - invoke the postgres binary directly (mirroring the platform's own
#     systemd unit) rather than pg_ctl start, whose exec-path resolution is
#     broken on this Nix-based image
#
# Run locally on the primary as a user with sudo (e.g. ubuntu).
set -euo pipefail

DEVICE="${1:?Usage: $0 <new-volume-device e.g. /dev/nvme2n1> <slot-name> <standby-port>}"
SLOT_NAME="${2:?slot name required}"
STANDBY_PORT="${3:-5433}"
MOUNT_POINT="/pgdata-new"
DATA_DIR="$MOUNT_POINT/data"
PRIMARY_PORT=5432

echo "=== Phase 1: filesystem ==="
sudo mkfs.ext4 -q "$DEVICE"
sudo mkdir -p "$MOUNT_POINT"
sudo mount "$DEVICE" "$MOUNT_POINT"
sudo chown postgres:postgres "$MOUNT_POINT"
sudo chmod 700 "$MOUNT_POINT"
UUID=$(sudo blkid -s UUID -o value "$DEVICE")
if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID  $MOUNT_POINT  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab
fi
df -h "$MOUNT_POINT"

echo "=== Phase 1: replication slot ==="
psql -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d postgres \
  -c "SELECT pg_create_physical_replication_slot('$SLOT_NAME');"

echo "=== Phase 1 fix: allow replication connections (database=all does not cover 'replication') ==="
if ! sudo grep -q "^host replication postgres" /etc/postgresql/pg_hba.conf; then
  echo "host replication postgres 127.0.0.1/32 trust" | sudo tee -a /etc/postgresql/pg_hba.conf
  echo "host replication postgres 10.0.0.0/8 scram-sha-256" | sudo tee -a /etc/postgresql/pg_hba.conf
  psql -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d postgres -c "SELECT pg_reload_conf();"
fi

echo "=== Phase 2: pg_basebackup ==="
time sudo -u postgres pg_basebackup \
  -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres \
  -D "$DATA_DIR" \
  --wal-method=stream --slot="$SLOT_NAME" \
  --checkpoint=fast --progress --write-recovery-conf

echo "=== Phase 2 fix: pre-stage standby config (port, listen_addresses, wal senders/slots) ==="
# Recovery aborts outright if these are lower on the standby than the primary
# (not just wal_senders/slots -- the runbook's own prerequisite list misses this).
PRIMARY_MAX_CONN=$(psql -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d postgres -t -A -c "SHOW max_connections;")
PRIMARY_MAX_LOCKS=$(psql -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d postgres -t -A -c "SHOW max_locks_per_transaction;")
PRIMARY_MAX_WORKERS=$(psql -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d postgres -t -A -c "SHOW max_worker_processes;")
sudo -u postgres bash -c "cat >> $DATA_DIR/postgresql.auto.conf" <<EOF
port = $STANDBY_PORT
listen_addresses = '*'
max_wal_senders = 10
max_replication_slots = 10
max_connections = $PRIMARY_MAX_CONN
max_locks_per_transaction = $PRIMARY_MAX_LOCKS
max_worker_processes = $PRIMARY_MAX_WORKERS
hot_standby = on
shared_buffers = 128MB
EOF

echo "=== Phase 2 fix: standby's own pg_hba.conf must also allow replication from replica hosts (both address families -- replicas may reach the primary over IPv6 even when IPv4 private routing between AZs is not available) ==="
sudo -u postgres bash -c "cat >> $DATA_DIR/pg_hba.conf" <<'EOF'
host replication postgres 10.0.0.0/8 scram-sha-256
host replication postgres ::/0 scram-sha-256
EOF

echo "=== Phase 2 fix: run under systemd (not a bare nohup process) ==="
sudo tee "/etc/systemd/system/postgresql-standby.service" > /dev/null <<EOF
[Unit]
Description=PostgreSQL standby (rehearsal, port $STANDBY_PORT)
After=network.target

[Service]
Type=simple
User=postgres
ExecStart=/usr/lib/postgresql/bin/postgres -D $DATA_DIR
Restart=always
RestartSec=5
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now postgresql-standby

sleep 3
echo "=== Verify ==="
psql -h 127.0.0.1 -p "$PRIMARY_PORT" -U postgres -d postgres -c \
  "SELECT application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;"
psql -h 127.0.0.1 -p "$STANDBY_PORT" -U postgres -d postgres -c "SELECT pg_is_in_recovery();"
