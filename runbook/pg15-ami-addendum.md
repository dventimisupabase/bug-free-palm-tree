# Addendum: PG15 AMI rehearsal

**Status:** Full rehearsal against a genuine PostgreSQL 15 project (`postgres_engine=15`, a different AMI from the PG17 rigs used everywhere else in this repo), created directly via the Management API (`POST /v1/projects` with `postgres_engine: "15"` — the CLI doesn't expose this parameter).

## Headline result: the runbook works unmodified on PG15

Ran `standby-setup.sh`, `reparent-replica.sh` (both replicas), and `cutover.sh` (including Phase 4.7) with **zero script changes**. Every AMI-specific mechanic found during the PG17 rehearsals held identically:

- Same Nix-store layout (`/nix/store/<hash>-postgresql-and-plugins-15.14/`, same symlink structure via `/usr/lib/postgresql/bin/postgres`)
- Same `pg_ctl start`/`promote` brokenness (same exec-path resolution failure) — invoking `postgres` directly and `SELECT pg_promote()` worked identically
- Same `supabase_admin` vs network-facing `postgres` role split — `ALTER SYSTEM`/`CHECKPOINT`/`pg_promote()` needed `supabase_admin` locally, exactly as on PG17
- Same three firewall layers (AWS SG, `ufw`, `nftables inet supabase_managed`) needed the same treatment
- Same Salt masking requirement for fencing (`Failed to mask unit: File ... already exists` — same fallback path, worked the same way)
- Same connection-limit matching requirement (`max_connections`/`max_locks_per_transaction`/`max_worker_processes`) for standby startup
- Cutover timing was consistent: PAUSE to RESUME in ~22 seconds, matching PG17 numbers

This significantly de-risks the concern that prompted this test — the AMI differences between Supabase's PG15 and PG17 images (which is a real, distinct-AMI difference, not just a bundled version bump) don't appear to affect anything this runbook touches. That's not proof there are zero PG15-specific gaps, but it's a strong data point in favor of the runbook and scripts generalizing.

## What we did NOT get to test

The planned "kill two birds" combination — using this PG15 run to also cover cross-region replicas (per issue #1) — didn't pan out. The read-replica setup API accepted requests for `us-west-2` and `eu-west-1` (HTTP 204 both times) but never actually provisioned anything in either region after several minutes of polling, with zero replication connections appearing on the primary. This looks like a staging-environment limitation (`supabase.green` may lack cross-region VPC peering / worker capacity that a real production environment has) rather than a genuine API failure, but we don't know for certain. Proceeded with same-region replicas instead; cross-region remains untested, tracked separately in issue #1.

## A real bug this test caught (now fixed, not PG15-specific)

Phase 4.7 (added in the previous round: move the new primary back to its original port so PostgREST/GoTrue/postgres_exporter/Supavisor self-heal) restarted Postgres **without pausing PgBouncer first**. This reintroduced exactly the hard client disconnects the rest of the procedure exists to avoid.

It surfaced as a confusing symptom: pgbench's own summary reported `number of failed transactions: 0 (0.000%)`, immediately followed by `pgbench: error: Run was aborted; the above results are incomplete.` — these are different failure categories in pgbench's own accounting (a mid-transaction failure vs. a hard connection-level crash, `FATAL: server conn crashed?`), so a naive read of "0 failed" would have missed this entirely. Caught only because the full log was actually read, not just the summary line.

Fixed by wrapping Phase 4.7's restart in its own `PAUSE`/`RESUME`, matching the main cutover sequence's pattern (see `runbook/cutover.sh`, committed separately). **Re-verified empirically**, not just by code review: since the original primary had lost SSH access again by the time the fix was ready to test (see below), verification was done in isolation against a still-reachable replica's own local Postgres + PgBouncer — paused, restarted Postgres, resumed, confirmed a live `--select-only` pgbench workload survived with `0 failed` and no abort, only the expected latency spike during the restart window.

## The SSH-access-loss pattern happened a fourth time

This PG15 primary lost SSH access again partway through, exactly like all three PG17 primaries before it (v1, v2, v3) — same symptom (`Permission denied (publickey)` after previously working fine), same profile of node (heavily modified: custom firewall rules, masked systemd unit, custom systemd units), same immunity for replicas (every replica in every rehearsal, including this one, stayed reachable throughout). This is now a 4-for-4 pattern specifically on nodes this runbook's own manual intervention touches heavily. Per earlier guidance this is being treated as orthogonal to the runbook's correctness and not re-investigated here, but it's worth someone owning the platform's SSH/EC2-Instance-Connect or fail2ban configuration taking a look independently — four-for-four is no longer a coincidence, even if it's not this runbook's problem to solve.

## Operational lesson, not a bug: pacing around replica retention

Early in this rehearsal, both pre-existing replicas briefly dropped out of `pg_stat_replication` and their walreceivers failed with `requested WAL segment ... has already been removed`. This happened because Phase 1/2's own `pg_basebackup` was started while the replicas' initial sync was still settling, and Supabase's managed replicas don't use replication slots (confirmed back in the PG17 rehearsals) — so WAL retention is time/size-based only, and three concurrent consumers (two replicas mid-sync plus a fresh manual basebackup) plus live pgbench write load was enough to recycle a segment before one replica had consumed it. Both replicas recovered on their own via archive-based fallback within a few minutes — not data loss, not a persistent failure — but it's a real timing sensitivity worth calling out: **confirm existing replicas are fully caught up and stable (not just "created") before starting Phase 1's `pg_basebackup`**, especially under sustained write load.
