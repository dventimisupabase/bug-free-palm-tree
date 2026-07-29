# Addendum: Full service ecosystem and IPv4 addon

**Status:** Third rehearsal (v3), testing beyond what runbook-v2 covered — the full set of things that talk to Postgres on a real project, not just PgBouncer-fronted application traffic, plus the IPv4 addon.

## IPv4 addon

Enabling the IPv4 addon (`PATCH /v1/projects/{ref}/billing/addons`, `addon_type=ipv4`, `addon_variant=ipv4_default`) adds a public IPv4 address to the instance's existing network interface alongside its private IPv4 and public IPv6 — purely additive, nothing removed or reconfigured. Ran the entire `standby-setup.sh` → `reparent-replica.sh` → `cutover.sh` sequence on a rig with the addon enabled throughout: no interference of any kind. **Confirmed non-issue**, no runbook changes needed.

## The real connection topology

Runbook-v2 was written and tested against PgBouncer-fronted application traffic only. That is not the only, or even the majority, path to the primary. On a real project:

| Consumer | Location | Connects via | Survives PAUSE? |
|---|---|---|---|
| Application traffic (well-behaved) | client | PgBouncer (:6543) | Yes — this is what runbook-v2 validated |
| PostgREST | on-box | direct to primary's port, no pooling | No |
| GoTrue | on-box | direct to primary's port, no pooling | No |
| postgres_exporter | on-box | direct to primary's port (implicit, no port in its DSN — defaults via libpq) | No |
| Direct/unpooled client connections | client | straight to the primary's port | No |
| **Supavisor** | **external, shared, not on this box** | direct to the primary's port | No, and its recovery is not just "backend comes back" (see below) |

Envoy (the on-box gateway) and Kong (present as a systemd unit but inactive in this environment) sit at the HTTP layer in front of PostgREST/GoTrue and never touch the Postgres wire protocol directly — unaffected by any of this.

Realtime and Storage, which we expected to find on the box, are **not present at all** on this project tier — no process, no systemd unit, no install path under `/opt`. Whatever true production topology has these deployed as, it isn't as an on-box process here; don't assume this rehearsal characterizes them.

## The decisive implication: the final port matters more than we thought

Runbook-v2 recommended keeping the new primary permanently on the new port (avoiding a second cutover). That recommendation is **reversed** by this finding: PostgREST, GoTrue, postgres_exporter, and Supavisor are all hardcoded to the *original* port, and none of them can be individually repointed by this runbook's own mechanism (Supavisor's backend target is separate control-plane state — a `pgbouncer_config` record plus an `ADD_AS_POOLER_TENANT` queue job — entirely outside what a manual, SSH-driven procedure can touch).

**New Phase 4.7**, added to `cutover.sh`: after promotion is validated on the new (temporary) port, do one more brief, controlled restart to move the new primary back to the *original* port. This is now the recommended default, not the exception. The cost is one additional few-second interruption; the alternative is individually finding and reconfiguring every hardcoded consumer, which is more failure-prone and, for Supavisor, not fully possible from this runbook's position at all.

## What actually happened when we tested this

Ran the full cutover (Phases 1-4, ending on the new port 5433), with all of the above monitored throughout, then Phase 4.7 (move back to 5432):

- **PostgREST**: hard `503` starting at the exact moment of fencing, for the entire duration the primary was on the "wrong" (new, temporary) port — then recovered to `200` **immediately and automatically** the moment Postgres came back on the original port. No config edit, no restart of PostgREST itself needed.
- **postgres_exporter**: stayed `200` throughout the entire test, apparently serving cached/stale metrics rather than failing on a live scrape error — a health signal that doesn't reflect live backend health. Worth knowing if this metric is used for alerting.
- **GoTrue**: `/health` stayed `200` throughout the entire test too, for the same reason — its health check doesn't appear to exercise a live DB connection. Don't trust this endpoint as evidence the database path is actually up.
- **Direct connections**: failed exactly as expected (`FATAL: the database system is shutting down`, then `Connection refused`) — this is the accepted, unavoidable cost the runbook was never trying to eliminate.
- **Supavisor**: failed immediately at fencing (`EAUTHQUERY: connection to database not available`), and — this is the important part — **did not recover when the backend did**. After the port-back-to-5432 fix, repeated connection attempts saw the error evolve: unavailable → stale-credentials → `auth_query secret check timed out` → **`ECIRCUITBREAKER: too many authentication failures, new connections are temporarily blocked`**. Supavisor has a circuit breaker over auth failures that, once tripped, blocks new connections for a cooldown period **independent of backend health**. It had not cleared after 5+ minutes of observation in this rehearsal (we stopped probing it deliberately, since repeated attempts may reset the breaker's own window rather than let it clear).

## What this means for the actual success criteria

Given the corrected bar (quick cutover, no split-brain, no data loss, client errors acceptable for anything that can't be gracefully paused): **this runbook meets it.** But "client errors acceptable" needs a caveat for Supavisor specifically — if a customer's application traffic goes through Supavisor rather than (or in addition to) an on-box PgBouncer, the customer-visible outage window is **not bounded by the cutover's own duration**. It's bounded by however long Supavisor's circuit breaker stays open afterward, which:

- We don't control from this runbook
- We don't have a measured value for (>5 minutes observed, exact recovery time unknown)
- Is presumably made worse, not better, by real application traffic all failing and retrying simultaneously during the port-mismatch window — the same mechanism that tripped it during our test with just one polling client

**Open item for a real cutover:** find out from whoever owns Supavisor (a) its circuit breaker's actual cooldown duration and reset conditions, and (b) whether there's a way to warn it in advance or reset it explicitly post-cutover, rather than waiting it out blind. Until that's answered, treat "how long is the real customer-visible window if they use Supavisor" as unresolved, not "a few seconds like the PgBouncer path."

## Other findings from this pass, lower stakes but worth carrying forward

- **`admin-mgr`** (a platform-internal CLI, `/usr/bin/admin-mgr`) coordinates long-running Postgres lifecycle operations (backup, restore, replica setup) via a host lock at `/var/run/admin-mgr/lock.json`, specifically to prevent exactly the kind of conflict this runbook's manual approach is structurally exposed to (its own README documents a prior "class of failed-restore incidents" from Postgres being restarted while admin-mgr was mid-operation). There is no generic "hold this lock for my own custom operation" command — the lock is only ever a side effect of admin-mgr's own supported operations — so we cannot acquire it for this runbook's purposes. What we *can* do, and should add to preflight: run `admin-mgr is-busy` before starting, to confirm nothing else is using it. (Its exit-code convention wasn't fully characterized in this pass — exit `1` with no lock file present and nothing obviously running; confirm what "busy" vs "not busy" actually look like before relying on it.)
- **fail2ban** runs three jails (`sshd`, `pgbouncer` at :6543, `postgresql` at :5432), each with `maxretry=3`. Repeated failed authentication against Postgres or PgBouncer during troubleshooting — easy to generate by accident while debugging a cutover issue — could trigger a ban. We did not confirm whether a ban in one jail cascades to blocking other ports (the jail configs didn't show an explicit `banaction_allports` override for either), but given this is exactly the kind of thing that could compound an SSH-access mystery like the one we hit twice in earlier rehearsals, avoid unnecessary repeated failed-auth attempts during a live procedure, and check `fail2ban-client status <jail>` if access problems appear.
