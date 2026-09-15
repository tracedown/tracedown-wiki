---
description: "How Tracedown's aggregate-worker rolls raw probe results into hourly and daily buckets, ages raw rows out, trims the outbox, and why it must not be replicated."
---
# Retention & Aggregation

A probe running every minute produces about 43,000 raw results a month, each
with a row per HTTP call and a full timing breakdown. Multiply by services and
by months and the raw table stops being something you can usefully query — the
"last 12 months" chart is scanning millions of rows to draw a few hundred
pixels. Tracedown's answer is to roll raw results into hourly and daily buckets
as they arrive and let the raw rows age out underneath, so long-range charts
read pre-computed aggregates and the expensive detail is kept only as long as
you actually need it for debugging.

All of this happens in the **aggregate-worker**.

!!! warning "Run exactly one aggregate-worker replica"
    The worker's jobs are plain coroutine loops launched at startup — a
    `while (isActive)` loop with a `delay()` between runs. There is **no
    distributed lock** and no leader election anywhere in the worker.

    A second replica does not split the work; it duplicates it. Two workers will
    both aggregate the same window and both run retention over the same rows,
    producing double-counted aggregates and redundant delete traffic. Unlike the
    scheduler, which uses Redis `SET NX` locking to make replicas safe, the
    worker has no such protection. Run one. See [Scaling](scaling.md).

## The jobs

Every job is launched at worker startup with an interval in seconds. Intervals
exist mainly so E2E tests can run everything fast; the defaults are sensible for
production.

| Job | Interval variable | Default | What it does |
|---|---|---|---|
| `HourlyAggregationJob` | `WORKER_INTERVAL_HOURLY_AGGREGATION` | `900` | Rolls raw results into hourly buckets; pushes response-time percentiles to Redis B |
| `DailyAggregationJob` | `WORKER_INTERVAL_DAILY_AGGREGATION` | `3600` | Daily rollups |
| `RetentionJob` | `WORKER_INTERVAL_RETENTION` | `3600` | Per organization: deletes raw results past `RESULT_RETENTION_DAYS` with the bodies still on them, then expires bodies past `BODY_RETENTION_DAYS` on the results it kept, over a time slice starting at a per-organization watermark |
| `AggregateRetentionJob` | `WORKER_INTERVAL_RETENTION` | `3600` | Deletes hourly aggregate rows past `HOURLY_AGGREGATE_RETENTION_DAYS`; keeps daily rollups |
| `PurgeJob` | `WORKER_INTERVAL_PURGE` | `300` | Hard-deletes soft-deleted rows whose `purge_after` has passed, and their stored bodies |
| `OutboxPurgeJob` | `WORKER_INTERVAL_RETENTION` | `3600` | Trims consumed outbox rows |
| `SessionCleanupJob` | `WORKER_INTERVAL_SESSION_CLEANUP` | `900` | Removes expired and stale-revoked sessions |
| `AgentHealthCleanupJob` | `WORKER_INTERVAL_RETENTION` | `3600` | Trims agent health history past `AGENT_HEALTH_RETENTION_DAYS` |
| `ExpiredInviteSweepJob` | `WORKER_INTERVAL_RETENTION` | `3600` | Soft-deletes expired never-accepted invites and their stub accounts |
| `OrphanUserPurgeJob` | — (fixed 1h) | `3600` | Marks accounts with no remaining memberships for deletion after a grace window |
| `AuditLogRetentionJob` | `WORKER_INTERVAL_RETENTION` | `3600` | Trims audit log entries past `AUDIT_LOG_RETENTION_DAYS` |
| `NotificationLogRetentionJob` | `WORKER_INTERVAL_RETENTION` | `3600` | Trims notification delivery history past `NOTIFICATION_LOG_RETENTION_DAYS` |
| `ExpiredTokenCleanupJob` | `WORKER_INTERVAL_RETENTION` | `3600` | Deletes expired password-reset tokens (no knob — expired tokens have no value) |
| `DomainReverifyJob` | — (fixed 24h) | `86400` | Re-checks domain verification; disabled when `TRUSTED_DOMAIN_MODE=true` |

Eight jobs share `WORKER_INTERVAL_RETENTION` — raw retention, aggregate
retention, outbox purge, agent health cleanup, the audit and notification log
trims, expired-token cleanup and the expired-invite sweep are all "trim old
rows" work with no reason to run on different schedules, so they are wired to
one knob.

`DomainReverifyJob` and `OrphanUserPurgeJob` are the exceptions with no
interval variable: the first is hardcoded to daily and is switched on or off
rather than tuned; the second runs hourly. Since
`TRUSTED_DOMAIN_MODE` defaults to `false`, it runs on a default install; set
`TRUSTED_DOMAIN_MODE=true` to disable it along with the other domain checks.

!!! note "The development stack overrides these"
    `docker/docker-compose.yml` sets shorter intervals (hourly aggregation every
    300s, daily every 600s, session cleanup every 600s) so a local stack shows
    results quickly. Those are development conveniences, not recommendations.
    Note it also sets `WORKER_INTERVAL_PURGE` to `3600`, which is *longer* than
    the `300` default.

## Retention windows

| Variable | Default | Applies to | Read by |
|---|---|---|---|
| `RESULT_RETENTION_DAYS` | `90` | Raw probe results, and the bodies still attached to them | aggregate-worker **and** api-gateway |
| `BODY_RETENTION_DAYS` | `-1` | Saved response bodies in the default store; they never outlive their result | aggregate-worker |
| `HOURLY_AGGREGATE_RETENTION_DAYS` | `365` | Hourly aggregates | aggregate-worker |
| `AGENT_HEALTH_RETENTION_DAYS` | `90` | Agent health-check history | aggregate-worker |
| `AUDIT_LOG_RETENTION_DAYS` | `90` | Audit log entries | api-gateway **and** aggregate-worker |
| `NOTIFICATION_LOG_RETENTION_DAYS` | `90` | Notification delivery history | aggregate-worker |
| `PURGE_RETENTION_DAYS` | `0` | Delay between soft-delete and hard purge | api-gateway |

`AUDIT_LOG_RETENTION_DAYS` is enforced by the worker's `AuditLogRetentionJob`;
the gateway reads the same variable for its own configuration, so set it
identically in both services. Trimming by age is unrelated to user erasure:
erasing an account keeps its audit entries (anonymized), this window is what
eventually ages them out.

The notification log gets its own knob rather than riding on
`RESULT_RETENTION_DAYS` because it answers a different question — "was the
alert actually sent?" is delivery evidence an operator may want to keep longer
than raw probe data, and the rows are tiny by comparison. Log entries survive
the deletion of the service or result they refer to (the links are cleared);
they are removed by this window, or immediately when their organization is
purged.

### Results and bodies age separately

`RESULT_RETENTION_DAYS` and `BODY_RETENTION_DAYS` are two windows over the same
rows, and they are separate because the two things are not the same size. A
probe result is a few hundred bytes of timings, assertions and status; the
response body behind it can be megabytes. Ninety days of results is cheap.
Ninety days of bodies is usually what fills the disk or the bucket. Splitting
the windows lets you shed the bulk and keep the history.

A body never outlives its result. The result pass takes whatever bodies are
still attached to the rows it deletes; the body pass then clears bodies older
than `BODY_RETENTION_DAYS` off the rows it kept. So the effective body lifetime
is the shorter of the two windows:

| `RESULT_RETENTION_DAYS` | `BODY_RETENTION_DAYS` | A body lives for |
|---|---|---|
| `90` | `-1` (the default) | 90 days — the body pass never runs and the body goes with its result, exactly as before 0.4.35 |
| `90` | `7` | 7 days, while the result keeps the full 90 |
| `90` | `90` | 90 days — the body window expires nothing the result window would not have taken anyway |
| `365` | `30` | 30 days of bodies under a year of results |
| `-1` | `30` | 30 days, under results that are never deleted |
| `-1` | `-1` | As long as the install lives |

`BODY_RETENTION_DAYS` defaults to `-1`, so the body window is off until you turn
it on: upgrading to 0.4.35 changes nothing at all, whatever your result window
is — the body pass does not run and bodies go out with their results as they
always have. A body window *longer* than the result window is equally
uneventful, since the result takes the body with it first.

### Keeping data forever

Every retention window is a whole number of days, and the two probe-data
windows — `RESULT_RETENTION_DAYS` and `BODY_RETENTION_DAYS` — read it the same
way:

- **greater than zero** — expire at that age.
- **less than zero** — never expire by age. `-1` is the documented spelling and
  the one to use; any negative value behaves identically.
- **zero** — not a value. The aggregate-worker refuses to start, failing
  configuration load with `BODY_RETENTION_DAYS must not be 0 — use -1 to never
  expire by age, or a positive number of days` (and the same message for
  `RESULT_RETENTION_DAYS`). The container exits before a single job runs, so a
  `0` is a stack that did not come up rather than data quietly kept or quietly
  deleted.

There is no single "retention is off" switch behind those two variables any
more. Each pass tests its own effective window before it does any work: a result
window that is not positive skips the result pass for that organization, a body
window that is not positive skips the body pass, and only when neither window is
positive does the job return without reading a row. Switching one window off
leaves the other running — that is the whole point of the 0.4.35 split, and the
reason `RESULT_RETENTION_DAYS=-1` no longer disables the job as a whole.

`HOURLY_AGGREGATE_RETENTION_DAYS`, `AGENT_HEALTH_RETENTION_DAYS`,
`AUDIT_LOG_RETENTION_DAYS` and `NOTIFICATION_LOG_RETENTION_DAYS` are the older
windows and still take any value of `0` or below as "keep forever". Write `-1`
in all of them regardless: it is the documented sentinel, it reads as
intentional, and it is the only spelling that means the same thing in every
window.

"Forever" means less for bodies than it does for the other windows.
`BODY_RETENTION_DAYS=-1` switches the body pass off; it does not pin the body in
place. The body still goes when its result goes — aged out under
`RESULT_RETENTION_DAYS`, or purged with a deleted service, project, workspace or
organization. Keeping bodies indefinitely therefore takes *both* windows:
`RESULT_RETENTION_DAYS=-1` **and** `BODY_RETENTION_DAYS=-1`, in which case plan
for the bucket as well as for the table.

!!! danger "RESULT_RETENTION_DAYS must match in two services"
    `RESULT_RETENTION_DAYS` is read by **both** the api-gateway and the
    aggregate-worker, and it means something different in each:

    - in the **gateway** it caps the usage window offered in the UI;
    - in the **worker** it is the cutoff for actually deleting rows.

    They must be set to the same value. If they drift, the UI offers a window
    the data no longer covers — set the gateway to 365 and the worker to 90 and
    the dashboard cheerfully lets users ask for a year of raw results, nine
    months of which the worker deleted. There is no cross-check at startup; the
    only symptom is empty charts.

### Reading a retention tick

Each tick logs the latency of its first body delete (`Retention: first body
delete for org … took N ms`) and one line per batch of 500 results (`Retention:
org … batch N — results, bodies, failures, elapsed`), then a per-org total. A
tick with a start line and no batch line within `STORAGE_S3_TIMEOUT_SECONDS`
(default 30) is waiting on the store; from 0.4.18 that wait ends in a recorded
failure rather than a silent stall, and `BodyDeletionRetryJob` picks the
object up on a later tick.

### Hourly aggregate retention

`AggregateRetentionJob` deletes hourly aggregate rows older than
`HOURLY_AGGREGATE_RETENTION_DAYS` (default 365), running on the shared
`WORKER_INTERVAL_RETENTION` schedule. Daily rollups are deliberately kept — they
are cheap and back the long-range charts once the raw results and hourly buckets
that fed them have aged out. As with the other windows, a value of `0` or
negative keeps hourly aggregates forever.

### Why aggregates outlive raw results

The default shape — 90 days raw, 365 days hourly — follows from what each is
for. Raw results are how you debug *this* failure: the request, the response,
the assertion that tripped, the body. That question is asked days after the
fact, rarely months. Aggregates are how you answer "has p95 latency drifted over
the year?", which needs coarse points across a long window and nothing else.

So raw rows are expensive and short-lived, aggregates are cheap and long-lived,
and the intended ratio keeps aggregates roughly four times longer. Raising
`RESULT_RETENTION_DAYS` to keep a year of raw detail is the expensive knob and
usually the wrong one — the long-range charts already read aggregates.

### Outbox trimming

`OutboxPurgeJob` trims the transactional outbox, but only where it is provably
safe: a row is deleted only once it is past the retention window **and** at or
below the slowest consumer cursor in `outbox_cursors`, and either already
published or not of the fast-path event type. Never deleting above the slowest
cursor is what stops a lagging consumer from silently losing events.

Its retention window is a fixed 7 days in code and is not exposed as an
environment variable — only its interval is configurable, via
`WORKER_INTERVAL_RETENTION`.

## Three-tier deletion

Deleting a workspace, project or service in the UI does not immediately remove
rows. Tracedown uses three columns:

| Column | Type | Meaning |
|---|---|---|
| `deleted` | boolean | Hidden from the UI and from queries |
| `deleted_at` | timestamp | When it was soft-deleted |
| `purge_after` | timestamp | When it becomes eligible for hard deletion |

Soft-delete sets `deleted` and `deleted_at`, and computes `purge_after` from
`PURGE_RETENTION_DAYS`. `PurgeJob` then hard-deletes rows whose `purge_after`
has passed:

```sql
DELETE FROM %s WHERE purge_after IS NOT NULL AND purge_after < now()
```

The default `PURGE_RETENTION_DAYS=0` sets `purge_after` to `deleted_at`, so the
next `PurgeJob` tick — within 5 minutes by default — removes the data for good.
Raise it to buy an undo window: `PURGE_RETENTION_DAYS=7` means a service deleted
by mistake is recoverable in the database for a week.

The split between soft-delete and purge exists because deletion is deep. Purging
a service also removes its probe results, aggregates, steps, allowed agents,
silences, variables and the stored response bodies behind them. Doing that
synchronously inside the request that clicked "delete" would mean a long
transaction against the largest tables in the database; deferring it to a
background job keeps the UI immediate and the deletes batched. `PurgeJob` works
leaf-first so foreign keys hold even where children carry no `purge_after` of
their own.

Each entity group (services, projects, workspaces, organizations, users, and
the individual leaf tables) purges in its own transaction. If one group fails —
say an unexpected constraint — the failure is logged, every other group still
purges, and the failed group is retried on the next tick.

Erasure is deliberately not scorched-earth. Purging a user account removes its
sessions, reset tokens, recovery codes and memberships, but keeps audit log
entries (with the actor link anonymized) and keeps resources the account
created — API keys, presets, variables, bootstrap tokens — with their
`created_by` cleared: they belong to the organization, not the person. An
account that still *owns* an organization is never purged; the job logs an
error and keeps it until ownership is transferred or the organization is
deleted. Purging an organization takes everything org-scoped with it, including
its groups, permissions, webhook bindings, notification history and audit log;
members' accounts and sessions survive with their org selection cleared.

## Body storage

`RetentionJob` and `PurgeJob` both delete stored response bodies before they
delete the rows that reference them, so the bodies do not outlive their results
and leak — whether the rows age out or are purged with a deleted service,
project, workspace or organization.

After that, within the same tick and the same batch budget, `RetentionJob` runs
a **body pass** over the rows the result pass kept. It runs per organization and
it runs *second* on purpose: the result pass is the one that frees rows, so it
gets the budget first and a busy body pass can never starve it.

The body pass does not scan all of history. Each organization carries a
watermark — the body cutoff the last completed pass reached — and the pass reads
only the slice between it and today's cutoff, so a steady-state tick looks at
the handful of results that crossed the window in the last hour rather than at
every result ever stored. Inside that slice it takes the steps that still carry
a platform-owned body, deletes the objects through the same confined client, and
clears the stored URL on the step with `bodyExpired` as the reason the body is
not there. The result rows are left alone — the timings, the assertions and the
status all stay, and the dashboard says the body is no longer stored rather than
implying it was never saved. Bodies in an `in_place` store are skipped, as they
are everywhere else. With the window off — which is the default — the pass does
not run at all and bodies go only with their rows, the pre-0.4.35 behaviour.
Objects the store fails to delete are recorded for `BodyDeletionRetryJob`
exactly as in the result pass.

!!! warning "A body the fence refuses is left completely alone"
    A delete the store *refuses* because the URI falls outside the worker's
    bucket, prefix or root is not a delete that failed — it is the worker
    telling you its fence does not match the ingestor's. The body pass treats it
    as exactly that: the row is left untouched, the stored URL survives, nothing
    is stamped `bodyExpired`, an ERROR is logged, and the pass stops for that
    organization for the rest of the tick. It never clears a reference to an
    object that is still sitting in the store. Fix
    `STORAGE_S3_BUCKET`/`STORAGE_S3_PREFIX` or `STORAGE_FILESYSTEM_ROOT` to
    match the ingestor's and the next tick proceeds.

That covers the bodies the platform owns. A body written by an agent assigned a
[body store](body-stores.md) is handled by the store's mode:

| Where the agent wrote it | What happens to the body | Who deletes it |
|---|---|---|
| No store — the default store | Stays in the default store | The worker, on `BODY_RETENTION_DAYS` or with its result, whichever comes first |
| An `import` store | Copied into the default store as the result lands, and removed from the store it came from | The worker, the same as any other default-store body |
| An `in_place` store | Stays where the agent wrote it; the gateway reads it on demand | **Nobody.** The platform never deletes from an `in_place` store |

So `import` stores change nothing here: by the time a result is queryable its
body is in the default store, and it ages out on the body window like everything
else that lives there.

`in_place` stores move the decision to whoever owns the bucket or the directory.
The worker deletes the *rows* on the normal schedule and leaves the objects
alone — deliberately, because the store is not the platform's to empty. If you
want those objects gone, put a lifecycle rule on the bucket or a cleanup job on
the directory.

!!! note "Deleting an `in_place` store does not delete its objects either"
    A store cannot be deleted while an agent, an outstanding bootstrap token or
    a stored body still names it. The forcing form — **Delete and forget
    bodies** — clears the URL on every step that pointed into the store,
    recording `storeRemoved` as the reason the body is unavailable, and drops
    the row. The results keep everything else; the objects are untouched in a
    store Tracedown no longer holds credentials for. See
    [Deleting a store](body-stores.md#deleting-a-store).

!!! danger "Do not roll the worker back past 0.4.33 once an `in_place` store is in use"
    The column that records which store a body lives in is undone by clearing
    the stored URL on every step that carries one. Rolling the schema back
    therefore turns every `in_place` body into "not stored", permanently — and
    those are exactly the bodies the platform never kept a copy of. See
    [Upgrading](upgrading.md#body-stores-0433).

The destination depends on one variable. **The presence of `STORAGE_S3_ENDPOINT`
is the on/off switch** — the worker builds an S3 client only if the endpoint is
set:

=== "Local disk (default)"

    No `STORAGE_S3_ENDPOINT`. Bodies live on the `tracedown-bodies` volume at
    `STORAGE_FILESYSTEM_ROOT` (`/data/bodies` by default) and retention deletes
    them from disk. Nothing else to configure — but the root is also the fence,
    so if you moved it, set the same value here as on the ingestor.

=== "S3-compatible store"

    ```bash
    STORAGE_S3_ENDPOINT=https://account.r2.cloudflarestorage.com
    STORAGE_S3_ACCESS_KEY=...
    STORAGE_S3_SECRET_KEY=...
    STORAGE_S3_BUCKET=tracedown-bodies
    STORAGE_S3_PREFIX=bodies
    ```

    `STORAGE_S3_ACCESS_KEY` and `STORAGE_S3_SECRET_KEY` must be set alongside
    the endpoint — the worker starts without them, but every delete then fails
    at runtime. `STORAGE_S3_BUCKET` and `STORAGE_S3_PREFIX` name the default
    store and must match the ingestor's, because they are also what the worker
    is allowed to delete inside. Any S3-compatible store works — R2, MinIO,
    Backblaze B2, Spaces.

!!! warning "The worker deletes only inside the location it is given"
    `STORAGE_S3_BUCKET` and `STORAGE_S3_PREFIX`, or `STORAGE_FILESYSTEM_ROOT`,
    fence the worker: a stored body whose URI falls outside them is skipped
    rather than deleted, and logged at WARN with a count for the run. That fence
    is what stops a misconfigured worker from deleting inside somebody's body
    store, and it is why the worker's three variables must match the
    result-ingestor's exactly.

    If `STORAGE_S3_ENDPOINT` is set with no `STORAGE_S3_BUCKET`, the worker
    falls back to deleting wherever a body's URI points, and warns at startup
    that it has done so — the pre-0.4.33 behaviour, kept so an upgrade cannot
    silently stop deleting. Set the bucket and prefix instead of living with it.

!!! warning "Credentials that cannot delete leave orphans"
    A body delete that fails is logged and the run carries on to remove the
    database rows anyway — neither retention nor purge aborts. That is the
    right trade (a broken bucket must not stop the database from being trimmed)
    but it means objects whose rows are gone stay in the bucket, with nothing
    left pointing at them. If the worker is configured for S3 storage, give it
    credentials that can actually delete, and watch the logs for
    `Failed to delete body at …` (retention) and
    `Failed to delete stored response body …` (purge).

## Tuning

| You want | Change |
|---|---|
| Longer raw history | Raise `RESULT_RETENTION_DAYS` **in both gateway and worker** |
| Keep raw results forever | `RESULT_RETENTION_DAYS=-1` in both gateway and worker; leave `BODY_RETENTION_DAYS=-1` too and the bodies stay with them |
| An undo window for deletions | Raise `PURGE_RETENTION_DAYS` |
| Less database growth | Lower `RESULT_RETENTION_DAYS`; long-range charts are unaffected |
| Less body storage growth, same history | Lower `BODY_RETENTION_DAYS`; results, charts and assertions are unaffected |
| Keep bodies for as long as their results | `BODY_RETENTION_DAYS=-1` — the default, and the body pass does not run at all |
| Faster cleanup after deletes | Lower `WORKER_INTERVAL_PURGE` |

Before raising raw retention, check whether the question you are trying to
answer needs raw rows at all. Trend questions are already served by aggregates
at whatever raw retention you have.

## Related

- [Body Stores](body-stores.md) — bodies the platform does not delete.
- [Scaling](scaling.md) — why the worker is single-replica.
- [Configuration](../install/configuration.md) — full environment reference.
- [Database & Migrations](../install/database.md) — schema and growth.
- [Monitoring Tracedown](observability.md) — watching the jobs run.
- [Troubleshooting](troubleshooting.md) — missing data, growth that will not stop.
