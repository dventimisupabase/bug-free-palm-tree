#!/usr/bin/env bash
# Phase 3 of the EBS right-sizing runbook: repoint one read replica onto the
# new standby (cascading), before promotion. Run locally on the replica.
#
# Fix baked in from rehearsal: ALTER SYSTEM fails for the network-facing
# 'postgres' role on Supabase-hosted nodes (it lacks superuser). Connect
# locally as supabase_admin instead -- pg_reload_conf() works for either role,
# but ALTER SYSTEM does not.
set -euo pipefail

STANDBY_HOST="${1:?Usage: $0 <standby-host> <standby-port> <slot-name> <application-name> <db-password>}"
STANDBY_PORT="${2:?}"
SLOT_NAME="${3:?}"
APP_NAME="${4:?}"
DB_PASSWORD="${5:?}"

export PGOPTIONS="-c pg_stat_statements.track=none"

psql -U supabase_admin -h localhost -d postgres -c \
  "ALTER SYSTEM SET primary_conninfo = 'host=$STANDBY_HOST port=$STANDBY_PORT user=postgres password=$DB_PASSWORD application_name=$APP_NAME sslmode=prefer';"
psql -U supabase_admin -h localhost -d postgres -c \
  "ALTER SYSTEM SET primary_slot_name = '$SLOT_NAME';"
psql -U supabase_admin -h localhost -d postgres -c "SELECT pg_reload_conf();"
unset PGOPTIONS

sleep 3
echo "=== Verify: walreceiver conninfo should show the standby's host:port ==="
psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c \
  "SELECT status, conninfo FROM pg_stat_wal_receiver;"
