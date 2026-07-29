# EBS Right-Sizing Runbook (Proof of Concept)

A rehearsed, scripted procedure for shrinking an overprovisioned EBS data volume
under a live PostgreSQL primary, on a Supabase-hosted (Nimbus) EC2 instance,
without taking the database fully offline and without breaking existing
streaming read replicas.

**Status: proof of concept.** Everything here was built and validated by hand,
one engineer, against real (test) Supabase projects, to de-risk a specific
customer migration before it's run for real. It is not production tooling: no
orchestration layer, no idempotent retries, no automated rollback, no tests
beyond "we ran it against a live rig and watched what happened." If this
strategy moves forward, expect another team to reimplement it properly
(probably folded into `admin-mgr` or an equivalent control-plane tool, not run
by hand over SSH). Treat this repo as the field notes that justify the
approach and flag its sharp edges, not as something to point at a real
customer as-is.

## The problem

A customer's PostgreSQL primary sits on an EBS volume much larger than the
database actually needs. Right-sizing means moving the data to a smaller
volume. The two obvious approaches both have a real cost:

- Snapshot/restore to a new, smaller volume: requires a real outage window
  while the restore completes.
- Grow-then-shrink is not a thing EBS supports for a "shrink" in place at all.

The strategy validated here instead builds a **second Postgres instance on the
same host**, on a new, right-sized volume, promotes it in place, and retires
the old volume. Because the promotion happens on the same machine, replicas
never need their network route recomputed and application traffic only pauses
for as long as it takes to run a handful of pre-staged commands, seconds, not
the time it takes to move any data.

## Strategy

```
Phase 0 (today):        primary(:5432, old vol) ──> replica-1
                                                ──> replica-2

Phase 3 (pre-cutover):  primary(:5432, old vol) ──> standby(:5433, new vol) ──> replica-1
                                                                            ──> replica-2

Phase 5 (done):         primary(:5433, new vol) ──> replica-1
                                                 ──> replica-2
                        old volume detached and deleted
```

1. Build a standby on a new, right-sized volume, on the same host, on a
   different port. Let it stream from the primary.
2. Re-parent every existing read replica onto the new standby (cascading
   replication) *before* touching anything irreversible. Rollback is trivial
   up to this point: just point the replicas back.
3. Pause the pooler, verify LSNs match exactly, fence the old primary, promote
   the standby, repoint the pooler, resume. This window is the only
   interruption and it's driven entirely by a script, not typed by hand.
4. Move the newly-promoted primary back onto the *original* port (a second,
   brief, paused restart) so everything hardcoded to that port self-heals.
5. Decommission the old volume.

See [`runbook/runbook-v2.md`](runbook/runbook-v2.md) for the full phase-by-phase
procedure, prerequisites, and failure-mode table.

## What's in this repo

| File | Purpose |
|---|---|
| [`runbook/runbook-v2.md`](runbook/runbook-v2.md) | The procedure itself: prerequisites, phases, failure modes, open items. Start here. |
| [`runbook/preflight.sh`](runbook/preflight.sh) | GO / GO-WITH-WARNINGS / NO-GO checks, run on the primary and each replica before scheduling a real window. |
| [`runbook/standby-setup.sh`](runbook/standby-setup.sh) | Phases 1-2: filesystem, replication slot, `pg_basebackup`, pre-staged standby config, systemd unit. |
| [`runbook/reparent-replica.sh`](runbook/reparent-replica.sh) | Phase 3: repoints one existing replica onto the new standby. Run once per replica. |
| [`runbook/cutover.sh`](runbook/cutover.sh) | Phase 4: the supervised, step-confirming cutover itself. |
| [`runbook/service-ecosystem-addendum.md`](runbook/service-ecosystem-addendum.md) | What happens to everything that isn't pooled application traffic: PostgREST, GoTrue, postgres_exporter, direct connections, Supavisor. Read before assuming "the pooler paused, so we're safe." |
| [`runbook/pg15-ami-addendum.md`](runbook/pg15-ami-addendum.md) | Confirms the runbook and scripts hold unmodified on the PG15 image, a genuinely different AMI from the PG17 rigs used everywhere else. |

`runbook-v2.md` supersedes an original v1 design document (not included here
in its pre-correction form) that this project was tasked with hardening; the
"What changed since v1" section at the top of `runbook-v2.md` is effectively a
list of everything v1 got wrong or missed, each one found by actually running
it, not by review.

## How this was validated

Four full rehearsals, each against its own disposable Supabase-hosted test
project (real EC2 instances, real EBS volumes, provisioned and torn down via
the AWS CLI and the Supabase Management API, never simulated):

1. **v1, manual.** Walked the original design doc by hand, found most of the
   corrections now baked into the scripts.
2. **v2, scripted.** Same procedure, now driven by `standby-setup.sh` /
   `reparent-replica.sh` / `cutover.sh`, with `pgbench` running throughout to
   catch anything the eye would miss.
3. **v3, full service ecosystem.** Everything that talks to Postgres besides
   the pooled application path: direct connections, PostgREST, GoTrue,
   postgres_exporter, and Supavisor (external, shared, out of this runbook's
   reach). Also confirmed the IPv4 addon doesn't interfere. This is where the
   Phase 4.7 port-restore step and the Supavisor circuit-breaker finding came
   from.
4. **PG15 AMI.** Same scripts, zero changes, against a genuinely different
   Postgres-major/AMI combination, to test whether the fixes found on PG17
   were PG17-specific or platform-wide. They were platform-wide.

The throughline across all four: **trust the rig, not the write-up.** Several
"fixes" looked correct on inspection and were wrong in practice (see Phase
4.7's pause bug, below), so every fix in this repo was re-run against a live
instance with a live workload before being called done, not just code-reviewed.

## Key findings

The full list is in `runbook-v2.md`; the ones most likely to bite a
reimplementation:

- **Three independent firewall layers**, not one: the AWS security group, host
  `ufw`, and a separate `nftables inet supabase_managed` table with its own
  default-drop policy. All three fail silently (dropped packets, not
  rejections) if the new standby's port isn't opened on all of them.
- **The network-facing `postgres` role is not a superuser** on Supabase-hosted
  nodes (`REPLICATION`/`CREATEROLE`/`CREATEDB`/`BYPASSRLS`, but not
  `SUPERUSER`). `ALTER SYSTEM`, `CHECKPOINT`, and `pg_promote()` need
  `supabase_admin`, reachable only locally.
- **`pg_ctl start`/`pg_ctl promote` are broken** on this Nix-based image
  (exec-path resolution picks a `share/` directory that doesn't exist).
  Invoke `postgres -D <datadir>` directly and use `SELECT pg_promote()`.
- **A plain `systemctl stop` is not fencing.** A Salt reconciliation agent
  (`supabase-admin-agent_salt.timer`, ~5 min cadence) restarts a
  stopped-but-unmasked unit. Fencing requires `systemctl mask`.
- **PgBouncer's `query_wait_timeout` (120s default) is a hard ceiling** on the
  whole pause window, not a target. This is also why the cutover is a script:
  done by hand it took 161 seconds and blew the default timeout; scripted, it
  runs in ~20.
- **The pooled path isn't the only path.** PostgREST, GoTrue, and
  postgres_exporter connect directly to the primary's port, bypassing the
  pooler entirely; so does Supavisor, which is external, shared, and has no
  `PAUSE`/`RESUME` at all. Keeping the new primary permanently on a new port
  (the original recommendation) would have left every one of these broken
  until manually reconfigured, which isn't even possible for Supavisor from
  this runbook's position. Moving the new primary back to the *original* port
  (Phase 4.7) lets all of them self-heal via ordinary reconnect logic instead.
- **Standby recovery aborts outright** if `max_connections`,
  `max_locks_per_transaction`, or `max_worker_processes` are lower than the
  primary's, not just the replication-specific settings the original design
  called out.

## Known limitations and open items

- **Supavisor's recovery time is unbounded and unmeasured.** It trips its own
  auth-failure circuit breaker during the port-mismatch window and does not
  clear when the backend recovers; observed open for 5+ minutes with no
  measured upper bound. If a customer's traffic goes through Supavisor, the
  real customer-visible outage window is *not* the cutover's duration, it's
  whatever this breaker's cooldown turns out to be. Unresolved; see
  `service-ecosystem-addendum.md`.
- **SSH access to the primary breaks partway through, 4 rehearsals out of 4**,
  always on the heavily-modified node, never on replicas. Never root-caused
  (ruled out credential expiry, IPv6-specificity, and Admin-Studio-specific
  causes). Tracked as
  [issue #2](https://github.com/dventimisupabase/bug-free-palm-tree/issues/2),
  treated as orthogonal to the runbook's correctness rather than a runbook bug.
- **Cross-region read replicas were never actually tested.** The staging
  environment's read-replica API accepted requests for other regions (HTTP
  204) but never provisioned anything, twice, likely a staging-environment
  limitation rather than a real API failure, but unconfirmed either way.
  Tracked as
  [issue #1](https://github.com/dventimisupabase/bug-free-palm-tree/issues/1),
  deliberately deferred rather than chased.
- **`admin-mgr`'s host lock can't be acquired for this runbook's own use.** It
  exists specifically to prevent Postgres-lifecycle conflicts (its own README
  cites a prior class of failed-restore incidents), but only ever locks as a
  side effect of its own supported operations. The closest this runbook gets
  is checking `admin-mgr is-busy` in preflight before starting, not holding
  the lock for the duration.
- **fail2ban runs on sshd, PgBouncer, and Postgres itself** with
  `maxretry=3`. Never confirmed as the cause of the SSH-loss pattern above,
  but plausible, and worth avoiding unnecessary repeated failed-auth attempts
  during a live procedure regardless.

## If this gets reimplemented for production

Things a from-scratch implementation should almost certainly do differently,
based on what broke here:

- **Don't drive it over SSH by hand-invoked scripts.** Every fragile step in
  this repo (firewall layers, the Salt reconciliation fight, the `pg_ctl`
  exec-path bug) exists because this runbook operates *outside* the
  platform's own control plane. A production version should be a first-class
  operation the platform's own tooling (`admin-mgr` or its successor) knows
  about and can hold its lock for, not a guest.
- **Solve Supavisor's backend repoint properly**, through whatever control-plane
  mechanism actually updates `pgbouncer_config` / triggers
  `ADD_AS_POOLER_TENANT`, instead of relying on a same-port coincidence to
  make it self-heal.
- **Automate the LSN-match and fencing verification**, don't rely on a human
  reading two `psql` outputs and pressing Enter. The logic is simple; the
  consequence of getting it wrong is a split-brain.
- **Re-run the full ecosystem test (`service-ecosystem-addendum.md`) against
  whatever the real production topology turns out to be** before trusting
  this repo's specific findings; this rehearsal's project tier didn't even
  have Realtime or Storage installed, so those two are genuinely untested
  here, not confirmed safe.
