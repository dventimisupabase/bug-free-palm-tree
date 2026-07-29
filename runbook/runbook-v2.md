# Runbook v2: PostgreSQL EBS Volume Right-Sizing via Same-Host Standby Switchover

**Status:** Revised after two full rehearsals against real Supabase-hosted (Nimbus) test projects. v1 is the original design document; this version corrects every place it was wrong, ambiguous, or missing a step, and points to tested scripts instead of ad-hoc commands.

**Scripts referenced below** (in this directory): `preflight.sh`, `standby-setup.sh`, `reparent-replica.sh`, `cutover.sh`. All four were run against a live rig and are the source of truth for exact commands — this document explains what they do and why, but if the two ever disagree, trust the script.

---

## What changed since v1 (read this first)

If you've run v1 before, here's the delta:

1. **`pg_hba.conf`'s `database = all` entries do not cover the `replication` pseudo-database.** You need an explicit `host replication <user> <cidr> <method>` line, for both the primary and the new standby, or `pg_basebackup`/streaming replication fails outright with "no pg_hba.conf entry for replication connection" despite every other `all`-scoped rule being wide open.
2. **`pg_basebackup`'s copied `postgresql.conf` defaults to loopback-only `listen_addresses`.** This is a postmaster-context GUC — a `pg_reload_conf()` after the fact does nothing. The standby must have `listen_addresses = '*'` staged *before* first start, and if you miss it, fixing it costs a restart, not a reload.
3. **Standby recovery aborts if `max_connections`, `max_locks_per_transaction`, or `max_worker_processes` are lower than the primary's values** — not just `max_wal_senders`/`max_replication_slots` as v1's prerequisites implied. Query the primary's actual values and match or exceed them on the standby before first start.
4. **Three independent firewall layers can block the standby's port, and all three fail silently (packet drop, not reject):** the AWS security group, host-level `ufw`, and — specific to Supabase-hosted nodes — a separate `nftables` table (`inet supabase_managed`) with its own default-drop policy and curated allowlist. `ufw status` looking fine tells you nothing about the third layer. Open all three, or use `tcpdump` on the target host to see whether SYNs even arrive before assuming it's a Postgres-level problem.
5. **Replicas may be in a different AZ, or a different AWS region entirely, from the primary.** Private IPv4 is not a safe assumption for `primary_conninfo` — it may not even be routable. Use the primary's public/global IPv6 address (or its DNS hostname) instead, and scope firewall rules to whatever the existing port-5432 rule already allows (see Phase 3).
6. **On Supabase-hosted nodes, the network-facing `postgres` role is not a superuser** (it has `REPLICATION`, `CREATEROLE`, `CREATEDB`, `BYPASSRLS` — enough for `pg_basebackup` and slot management — but not `SUPERUSER`). `ALTER SYSTEM`, `CHECKPOINT`, and `pg_promote()` all require real superuser. Connect locally (via SSH) as `supabase_admin` for these specific calls; `pg_reload_conf()` works for either role.
7. **`pg_ctl start` and `pg_ctl promote` are broken on this platform's Nix-based Postgres image.** `pg_ctl`'s executable-discovery logic resolves the wrong `share/` directory through the `/usr/bin/*` symlink chain and fails with "could not open directory .../timezonesets". Invoke `postgres -D <datadir>` directly (mirroring the platform's own systemd unit), and use `SELECT pg_promote();` instead of `pg_ctl promote`.
8. **A plain `systemctl stop` is not sufficient fencing.** A Salt-based reconciliation agent (`supabase-admin-agent_salt.timer`, ~5 minute cadence) treats a stopped-but-enabled unit as configuration drift and restarts it — we watched the old primary come back to life as a stale, writable, timeline-1 primary about 6 minutes after "fencing" it. Fencing must `systemctl mask` (or manually symlink the unit to `/dev/null` if `mask` refuses because the file isn't already a symlink), not just stop.
9. **The default PgBouncer `query_wait_timeout` (120s) is a hard ceiling on the whole PAUSE-to-RESUME window, not a nice-to-have target.** If your cutover takes longer than this — easy to do the first time, doing it by hand, checking things carefully — every paused client gets forcibly disconnected with `FATAL: query_wait_timeout`, which is exactly the kind of error the procedure exists to avoid. Raise it (e.g., to 300s) before pausing. This is also why Phase 4 is a script now, not a checklist: scripted, it completes in ~20 seconds; done by hand the first time, it took 161 seconds and blew the default timeout.
10. **The promoted standby needs its own systemd unit before you rely on it**, not a bare `nohup`'d process. We hit this gap directly: nothing was supervising the promoted primary, and it would not have survived a crash or reboot. `standby-setup.sh` creates this unit as part of Phase 2, not deferred to Phase 5.
11. **Root volume size is independent of compute size tier** — choosing a larger instance size does not give you a bigger root volume; it's fixed at the AMI level (~10GB) regardless of `nano` through `medium` at least. If you need root headroom, resize the root EBS volume directly (and note it has a real partition table — `growpart` then `resize2fs`, unlike the whole-disk data volume).
12. **Encrypt the new standby volume to match the primary's existing volumes.** It will hold a full copy of live data; nothing in v1 mentions this.

None of the above changes the overall strategy (same-host standby, cascade the replicas onto it pre-promotion, fence-then-promote). They're all corrections to the mechanics.

---

## Objective and strategy (unchanged from v1)

Migrate a PostgreSQL primary from an overprovisioned EBS volume to a smaller, right-sized volume on the same host, with (a) write downtime limited to a PgBouncer pause of seconds and (b) zero interruption to existing streaming read replicas.

Build a new standby on the new volume (second postmaster, same host, different port). Re-parent the existing read replicas onto the new standby (cascading replication) *before* promotion, so they follow the timeline switch automatically. Promote behind a PgBouncer pause. Fence the old primary. Delete the old volume.

```
Phase 0 (today):        primary(:5432, old vol) ──> replica-1
                                                ──> replica-2

Phase 3 (pre-cutover):  primary(:5432, old vol) ──> standby(:5433, new vol) ──> replica-1
                                                                            ──> replica-2

Phase 5 (done):         primary(:5433, new vol) ──> replica-1
                                                 ──> replica-2
                        old volume detached and deleted
```

**Topology note:** replicas are independent hosts (potentially different AZ or region), not same-host processes. If your environment genuinely only has one box available for the whole rehearsal, same-host replica postmasters on alternate ports remain a valid documented deviation — but treat that as the exception, not the default assumption, and if you do it, everything in finding #5 above about addressing still applies the moment any replica is *not* on the same host.

---

## Assumptions and prerequisites

Run `preflight.sh --role primary` on the primary and `preflight.sh --role replica` on each replica. It checks, with a clear per-check PASS/WARN/FAIL and an overall GO / GO WITH WARNINGS / NO-GO:

- PostgreSQL ≥ 13 (PG13+ allows `primary_conninfo` changes via reload; PG12 replicas need a brief staggered restart in step 3.2 instead)
- No logical replication slots on the primary (hard blocker — physical basebackup can't carry these; pre-PG17 there's no sync mechanism)
- A role with `REPLICATION` (or superuser) for basebackup/slot creation, **and separately** a path to real superuser (`supabase_admin` locally) for the `ALTER SYSTEM` steps — these are different requirements and the script checks them separately
- A pause-capable proxy in front of the primary (PgBouncer, confirmed locally where possible)
- Volume sizing: current DB size + WAL headroom + 30–50% growth margin, checked against an optional `--new-volume-size-gb` argument
- Instance headroom (`MemAvailable`) for a second postmaster during phases 1–4
- OS privileged access (sudo) and DB superuser access
- WAL archiving active (`archive_mode=on`) — full restore-tested backup still requires manual confirmation; no script can verify this end-to-end without actually doing a restore

**Not automatable, confirm manually regardless of what the script says:**
- The most recent base backup + WAL archive genuinely restores
- All application traffic actually routes through the pause-capable proxy, not direct to the database port
- Whether replicas are same-region/same-AZ as the primary or not (affects addressing choice in Phase 3)

---

## Phase 1 — Provision and prepare the new volume

Run the AWS-side provisioning from an operator machine with the appropriate credentials, then the box-side setup via `standby-setup.sh` (covers Phase 1 remainder + all of Phase 2).

1.1. Create a new **encrypted** gp3 volume matching the primary's current performance characteristics (IOPS/throughput), in the same AZ as the primary instance, and attach it at the next free device slot:
```bash
aws ec2 create-volume --region <region> --availability-zone <az> \
  --volume-type gp3 --size <N> --iops 3000 --throughput 125 --encrypted \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=<name>}]'
aws ec2 attach-volume --region <region> --volume-id <vol-id> --instance-id <instance-id> --device /dev/sdf
```
Do not skip `--encrypted` if the primary's existing volumes are encrypted (check with `aws ec2 describe-volumes`) — this volume will hold a full copy of live data.

1.2. On the box, find the actual NVMe device (`lsblk` — the EBS `/dev/sdf` you specified is a logical hint; Nitro instances expose it as `/dev/nvmeXn1`, discovered by attachment order, not by the name you requested).

1.3. Run `standby-setup.sh <device> <slot-name> <standby-port>` — this handles the remainder of Phase 1 (filesystem, mount, fstab, replication slot, the `pg_hba.conf` replication-line fix) and all of Phase 2 (basebackup, pre-staged config including the connection/lock/worker-limit fix and `listen_addresses`, and standing up a proper systemd unit for the standby). See the script for exact commands.

**Verify (script does this automatically at the end):** `df -h` on the mount point shows expected size; `pg_stat_replication` on the primary shows the standby streaming with near-zero lag; the standby responds to `SELECT pg_is_in_recovery()` with `t` and matches the primary's timeline.

---

## Phase 2 — Build the standby

Covered by `standby-setup.sh` above. Key corrections baked in (see "What changed" #1–#3, #7, #10, #12):

- `listen_addresses = '*'` staged before first start
- `max_connections`, `max_locks_per_transaction`, `max_worker_processes` queried from the primary and matched
- `pg_hba.conf` on the standby gets explicit `replication` lines for both the CIDR range you expect replicas to connect from *and* an IPv6 rule (see Phase 3)
- Started via a dedicated systemd unit (`postgresql-standby.service`), not a bare process — this is what makes the promoted primary survive a crash or reboot after Phase 4

If `pg_basebackup` reports `permission denied` or `no pg_hba.conf entry for replication connection`, this is the #1 finding above — the script handles it, but if you're improvising, that's where to look first.

---

## Phase 3 — Re-parent the read replicas onto the new standby

3.1. Slots for each replica are created on the standby (part of Phase 1 sequencing in the scripts — create them right after the standby is up, before touching any replica).

3.2. On **each replica**, run `reparent-replica.sh <standby-host> <standby-port> <slot-name> <application-name> <db-password>`. Key points:

- **`<standby-host>` must be an address the replica can actually route to.** Do not default to the primary's private IPv4. If the replica is in a different AZ or region, private IPv4 may simply not be routable — use the primary's public/global IPv6 address or its DNS hostname (whatever the existing, working replication already uses — check `pg_stat_wal_receiver`'s `conninfo` on a currently-healthy replica for the address format actually in use before you assume anything).
- The script connects locally as `supabase_admin` for the `ALTER SYSTEM` calls (finding #6) — this only works via a local/SSH connection, not the network-facing role.
- Before running this on the first replica, confirm the standby's port is actually reachable from that replica's host: check the AWS security group (does it cover the address family you're using — **IPv4 rules do not cover IPv6 traffic and vice versa, add both** if you're not sure which the replica will use), the host's `ufw`, and — Supabase-hosted nodes specifically — the `nftables inet supabase_managed` table's `inbound` chain. The existing port-5432 rule's exact CIDR/allowlist scope is the thing to replicate for the new port, not a blanket `0.0.0.0/0`/`::/0` (that's a shortcut for a rehearsal, not a production security posture).
- If the connection times out (not "connection refused"): that's a firewall/routing problem, not a Postgres problem. Use `tcpdump -i any port <standby-port>` on the standby's host while triggering a connection attempt from the replica — if no packets arrive at all, it's the network layer (security group, NACL, or address-family mismatch); if packets arrive but nothing responds, check the Postgres logs on the standby.

3.3. **Verify before touching the next replica:** the script's own verify step checks `pg_stat_wal_receiver` on the replica for `status=streaming` and the expected `host:port` in `conninfo`. Also check `pg_stat_replication` on the standby for the new `application_name` in `streaming` state.

3.4. Repeat for each remaining replica, one at a time.

3.5. **Verify final pre-cutover topology:** primary's `pg_stat_replication` shows *only* the standby; the standby's shows every replica, all `streaming`, with LSNs advancing.

**Rollback at this phase is trivial:** repoint replicas back to the primary the same way. Nothing is burned yet.

---

## Phase 4 — Cutover

Run `cutover.sh <standby-port> <pgbouncer-admin-password>`. It is interactive — a human presses Enter to confirm each step, per the ground rule that irreversible actions get explicit confirmation — but every command within a step is pre-staged, so the actual PAUSE-to-RESUME window is a matter of seconds, not minutes. **This matters**: see finding #9. Do not attempt this phase by manually typing each command for the first time during a real window; rehearse with the script first.

Sequence (all corrections from "What changed" folded in):

1. **Raise `query_wait_timeout`** in `pgbouncer.ini` (e.g., to 300s) and reload, *before* pausing.
2. **PAUSE.**
3. **Checkpoint + verify LSN match** — `CHECKPOINT` as `supabase_admin` (needs real superuser), then compare `pg_current_wal_lsn()` on the primary against `pg_last_wal_replay_lsn()` on the standby. They must match exactly before proceeding. If they don't, abort (`RESUME` without promoting) and investigate.
4. **Fence the old primary** — `systemctl stop`, then `systemctl mask` (or the manual symlink-to-`/dev/null` fallback if `mask` refuses). Stopping alone is not fencing on this platform (finding #8).
5. **Promote** — `SELECT pg_promote();` as `supabase_admin` on the standby, not `pg_ctl promote` (finding #7). Verify `pg_is_in_recovery()` returns `f`.
6. **Repoint PgBouncer** — edit the `[databases]` connect string to the new port, `RELOAD`, then `RECONNECT` to proactively drop pooled connections to the now-dead old primary rather than waiting for them to fail on next use.
7. **RESUME.**

**Post-cutover verification:** new primary accepts writes (through the proxy); `pg_walfile_name(pg_current_wal_lsn())`'s leading 8 hex digits show the incremented timeline (`pg_control_checkpoint()`'s cached `timeline_id` may lag briefly — don't trust it if checked within the first second or two); every replica shows up in the new primary's `pg_stat_replication`, streaming, with advancing LSN; application error rate back to baseline.

**What "irreversible" means here, precisely:** once the old primary is fenced (step 4) and the standby is promoted (step 5), there is no same-timeline rollback. The old primary's data is still intact and could be restarted as a standalone fallback (no writes were lost if the pause held and the LSN check in step 3 passed), but doing so means reconciling anything written on the new timeline and re-parenting the replicas back. The LSN-equality check and fencing order exist specifically to make promotion boring.

---

## Phase 5 — Decommission

5.1. In production, soak the new topology for an agreed period (3–7 days) before deleting anything — the rehearsal compresses this, real cutovers should not.

5.2. Confirm the old primary's unit stays masked (it will — Salt's reconciliation can't override a masked unit, confirmed by testing an explicit `systemctl start` against it post-mask and watching it fail). Confirm the new primary's systemd unit is `enabled` (set up back in Phase 2 — if you're migrating from a v1-style rehearsal where the standby was a bare process, do this now, before anything else).

5.3. Housekeeping: check `pg_replication_slots` on the new primary for orphans (should show exactly the replica slots, all active); decide on the port going forward (recommend keeping the new port permanently rather than a second cutover back to the original port number — fewer moving parts, no additional pause window; document whichever you choose). Update backup jobs, monitoring targets, and anything else referencing the old data directory or port.

5.4. Retire the old volume:
```bash
aws ec2 create-snapshot --volume-id <old-vol-id> --description "pre-delete snapshot"
```
On the box: `umount`, remove the `/etc/fstab` entry, then:
```bash
aws ec2 detach-volume --volume-id <old-vol-id>
aws ec2 wait volume-available --volume-ids <old-vol-id>
aws ec2 delete-volume --volume-id <old-vol-id>
```
**The delete is the deliverable** — a detached-but-retained volume still bills. Treat the delete as its own confirmation gate, separate from the rest of the phase; everything before it (snapshot, unmount, detach) is reversible, the delete is not.

**Verify:** billing line item for the old volume ends; `df -h` shows only the new volume; the new primary's postmaster has its own systemd unit and survives a manual restart test.

---

## Failure modes and responses

| Symptom | Phase | Response |
|---|---|---|
| `pg_basebackup`/replication fails with "no pg_hba.conf entry for replication connection" | 2 | `database=all` doesn't cover `replication` — add an explicit line |
| Standby won't accept remote connections despite `pg_stat_replication` showing it listening locally | 2/3 | Check `listen_addresses` (needs restart, not reload, if wrong) |
| Standby refuses to start: "recovery aborted because of insufficient parameter settings" | 2 | `max_connections`/`max_locks_per_transaction`/`max_worker_processes` lower than primary — match them |
| Replica's connection to the standby times out (not refused) | 3 | Network layer, not Postgres. Check, in order: address family mismatch (IPv4 vs IPv6), AWS security group, host `ufw`, and (Supabase-hosted) the `nftables supabase_managed` table. `tcpdump` on the standby settles it |
| `ALTER SYSTEM` fails with "permission denied to set parameter" | 3/4 | Connecting as the network-facing role, not a real superuser — use `supabase_admin` locally |
| `pg_ctl start`/`promote` fails with a `share`/`timezonesets` directory error | 2/4 | Broken exec-path resolution on this image — invoke `postgres`/use `pg_promote()` directly |
| Old primary comes back on its own minutes after being "fenced" | 4 | Not actually fenced — `systemctl stop` alone isn't enough where a reconciliation agent (Salt or similar) treats it as drift. Mask the unit |
| pgbench/app clients get `FATAL: query_wait_timeout` disconnects during cutover | 4 | The pause took longer than PgBouncer's timeout. Raise it before pausing, and make sure the actual command sequence is scripted, not manually typed for the first time |
| App errors after RESUME | 4 | PgBouncer pointed at wrong port, `RECONNECT` not issued (stale pooled connections to the dead primary), or old primary not actually stopped — recheck fencing and the repoint step |
| Replica does not follow new timeline | 4 | Check `recovery_target_timeline='latest'`; confirm it can still reach the new primary's port post-promotion |
| Promoted primary doesn't survive a reboot/crash | 5 (should be caught in 2) | No systemd supervision was ever set up — this should have happened in Phase 2, not deferred |

---

## Open items to resolve before scheduling a real cutover

1. Exact PostgreSQL version on all three production nodes.
2. Presence of any logical/CDC replication slots (hard blocker if present).
3. Whether production writes traverse PgBouncer today, confirmed for real traffic, not just the connection an engineer happens to test with.
4. Replica connection topology in production: same AZ, different AZ, or different region from the primary? This directly determines whether private IPv4 is viable at all (per finding #5) — do not assume based on this rehearsal's specific layout, check the actual production topology.
5. Whether production nodes are Supabase-hosted (in which case every fix in this document applies directly) or self-managed by the customer (in which case the `postgres` role likely *is* a real superuser, `pg_ctl` likely works normally, and there's no Salt-equivalent reconciliation agent to fight — verify before assuming any of these findings carry over).
6. Agreed soak period and final port decision.
