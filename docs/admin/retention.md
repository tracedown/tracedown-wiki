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
| `RetentionJob` | `WORKER_INTERVAL_RETENTION` | `3600` | Deletes raw results past `RESULT_RETENTION_DAYS`, and their stored bodies |
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
| `RESULT_RETENTION_DAYS` | `90` | Raw probe results and their bodies | aggregate-worker **and** api-gateway |
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

### Keeping data forever

`RESULT_RETENTION_DAYS`, `HOURLY_AGGREGATE_RETENTION_DAYS`,
`AGENT_HEALTH_RETENTION_DAYS`, `AUDIT_LOG_RETENTION_DAYS` and
`NOTIFICATION_LOG_RETENTION_DAYS` treat `-1` as "keep forever". In practice the
guard is `<= 0`, so `0` and any negative value also disable deletion:

```kotlin
if (defaultRetentionDays <= 0) {
    log.debug("Retention disabled (resultRetentionDays={})", defaultRetentionDays)
    return
}
```

Use `-1` — it is the documented sentinel and it reads as intentional. Setting
`RESULT_RETENTION_DAYS=0` expecting "delete everything immediately" does the
exact opposite and keeps raw results forever.

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

The destination depends on one variable. **The presence of `STORAGE_S3_ENDPOINT`
is the on/off switch** — the worker builds an S3 client only if the endpoint is
set:

=== "Local disk (default)"

    No `STORAGE_S3_ENDPOINT`. Bodies live on the `tracedown-bodies` volume at
    `/data/bodies` and retention deletes them from disk. Nothing else to
    configure.

=== "S3-compatible store"

    ```bash
    STORAGE_S3_ENDPOINT=https://account.r2.cloudflarestorage.com
    STORAGE_S3_ACCESS_KEY=...
    STORAGE_S3_SECRET_KEY=...
    ```

    `STORAGE_S3_ACCESS_KEY` and `STORAGE_S3_SECRET_KEY` must be set alongside
    the endpoint — the worker starts without them, but every delete then fails
    at runtime. Any S3-compatible store works — R2, MinIO, Backblaze B2,
    Spaces.

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
| Keep raw results forever | `RESULT_RETENTION_DAYS=-1` in both |
| An undo window for deletions | Raise `PURGE_RETENTION_DAYS` |
| Less database growth | Lower `RESULT_RETENTION_DAYS`; long-range charts are unaffected |
| Faster cleanup after deletes | Lower `WORKER_INTERVAL_PURGE` |

Before raising raw retention, check whether the question you are trying to
answer needs raw rows at all. Trend questions are already served by aggregates
at whatever raw retention you have.

## Related

- [Scaling](scaling.md) — why the worker is single-replica.
- [Configuration](../install/configuration.md) — full environment reference.
- [Database & Migrations](../install/database.md) — schema and growth.
- [Monitoring Tracedown](observability.md) — watching the jobs run.
- [Troubleshooting](troubleshooting.md) — missing data, growth that will not stop.
