---
description: "Upgrading self-hosted Tracedown: the Flyway schema-migrator runs to completion before any service starts, plus backups, undo scripts and upgrading probe agents."
---
# Upgrading

Upgrading Tracedown is mostly uneventful, because the schema migration is not
your job. The `schema-migrator` service runs to completion before any
application service starts, and compose enforces that ordering. The shape of an
upgrade is therefore: pull the new code, build, bring the stack up, and let the
migrator go first.

## How the ordering is enforced

`schema-migrator` is a one-shot container, not a long-running service. It is
Flyway with a single `flyway_schema_history` table. On start it retries the
database connection up to 30 times at 2-second intervals — which is why you can
bring the whole stack up at once without racing Postgres — then applies pending
migrations and exits **0** on success or **1** on failure.

Every application service declares `condition: service_completed_successfully`
on the migrator. If migration fails, the migrator exits non-zero and the
services never start. You get a stack that did not come up, rather than a stack
running against a half-migrated schema. That is the intended failure mode.

See [Database & Migrations](../install/database.md).

## Before you upgrade

Two things, both cheap, both painful to skip.

**Back up Postgres.** The migrator applies schema changes in place. See
[Backup & Restore](backup.md).

**Confirm `PLATFORM_AES_KEY` is unchanged.** This key encrypts variables and
agent material. If it differs across the upgrade — a regenerated `.env`, a new
secret manager entry — the existing encrypted data is orphaned: still there,
no longer decryptable. Verify the value carries over before you start, not
after. See [Secrets & Encryption](secrets.md).

## The upgrade

All Lace libraries are pinned Maven Central dependencies, so there is no
version coordination to manage — pulling the backend repository is the whole
source update.

=== "Docker Compose"

    ```bash
    # 1. Pull the backend repository
    # 2. Back up Postgres
    # 3. Build and start — the migrator runs first
    docker compose up -d --build
    ```

=== "With resource limits"

    ```bash
    docker compose -f docker-compose.yml -f docker-compose.limits.yml up -d --build
    ```

Watch the migrator before assuming success:

```bash
docker compose logs tracedown-migrator
```

It logs the number of migrations applied. Services starting at all is itself
evidence the migration succeeded, given the gating above.

## Run handles, idempotency and the event feed (0.4.59–0.4.60)

Release 0.4.59 gives a run asked for through the API a handle (`runId`) to
follow it by, and adds result filters, the raw body download, script
validation, `Idempotency-Key` on every `POST`, and agent health on
`GET /agents`. Release 0.4.60 adds script presets, notification templates, the
warning log and the event feed to the API. Everything is additive: no route or
field a client already uses changes. See [The API](../guide/api.md).

**The schema changes.** Four migrations, two per release, each run under
`SET LOCAL lock_timeout = '5s'`: behind a long transaction they fail fast
instead of queueing every writer behind them, and the migrator can simply be
run again.

- 0.4.59 creates `run_requests`, one row per run asked for, and adds two
  columns to `probe_results`: `trigger` (`NOT NULL DEFAULT 'schedule'`) and a
  nullable `run_id`. On PostgreSQL 11 and later both are catalogue changes:
  the big table is not rewritten, and every existing result reads as
  `schedule`.
- 0.4.60 adds three columns to `outbox` — `xid`, the writing transaction;
  `organization_id`; and `inserted_at`, when the row was written — each added
  without a default and given one afterwards, so no row is rewritten and
  existing rows keep nulls. It creates the one-row `outbox_retention`, and a
  partial index on `outbox (organization_id, xid, seq)`.

**On a large outbox, build the index first.** The index migration is a plain
`CREATE INDEX`, which holds a lock that blocks writes to the outbox — every
result ingested — while it scans. The outbox is trimmed to 7 days, so this is
usually short. If yours is large, build the index by hand before deploying,
outside a transaction; the migration then finds it and does nothing:

```sql
CREATE INDEX CONCURRENTLY idx_outbox_organization_feed
    ON outbox (organization_id, xid, seq)
    WHERE organization_id IS NOT NULL;
```

The migration cannot do this itself: `CREATE INDEX CONCURRENTLY` waits for
every transaction that can see the table, including the one Flyway holds
across its whole run, so it would hang. If a concurrent build fails part-way,
drop the invalid index it leaves and run it again.

**Deploy in this order: the migrator; then result-ingestor, aggregate-worker,
probe-scheduler and notification-dispatcher; then api-gateway.** A single
`docker compose up -d` restarts everything after the migrator at once, which is
fine. The order matters when you roll services one at a time, or run replicas:

- **The ingestor before the scheduler.** A new scheduler records skipped rows
  with new `run_*` reasons; an older ingestor takes them for a capacity
  problem and raises a banner.
- **The worker before the gateway.** The 0.4.60 purge moves the event feed's
  retention mark as it deletes; an older one deletes without moving it, and a
  feed cursor could pass rows it deleted without being told. The 0.4.59 worker
  is also what purges old run requests.
- **Every service that writes to the outbox before the gateway.** Outbox rows
  written by a service still on an older release carry no organization, and
  the feed never delivers them. The feed is new, so nothing is lost but the
  rollout window — but the gateway is best last.

While versions are mixed, runs keep running, without their handles:

- a new gateway with an old scheduler: nobody hears the new run channel, the
  gateway falls back to the old one, and the old scheduler runs the run as it
  always did — not filed under its id, so its handle reads `expired` after the
  bound;
- an old gateway with a new scheduler: the run is made as a manual run with
  no id;
- scheduler replicas of both versions: a run waiting behind a lock an old
  replica holds is made without its id, and its handle expires;
- an old ingestor ignores the run's id and trigger: the handle still finds the
  result filed under the id, but `trigger=manual` does not, and the run is not
  settled in `run_requests`.

Results recorded before 0.4.59, or during the mixed window, read as
`trigger` `schedule`.

**The new environment variables are optional.** The gateway now reads
`PROBE_DEFAULT_TIMEOUT_MS`, the scheduler's variable — set it on both, to the
same value, if you set it at all — and `RUN_REQUEST_EXPIRY_SECONDS` and
`IDEMPOTENCY_ORG_BUDGET_BYTES`. Every service with a database pool now asks
PostgreSQL to end sessions left idle inside a transaction for 60 seconds
(`DB_IDLE_IN_TRANSACTION_TIMEOUT_SECONDS`, `0` for no limit). The
result-ingestor now reads `MAX_VARS_PER_RESOURCE` as well, to cap the keys one
run's writeback may write; if you set it on the gateway, set it on the ingestor
too. See
[Configuration](../install/configuration.md#run-handles-and-idempotent-requests).

**Give long-polls 30 seconds.** `GET /api/public/v1/events` can hold a request
open for up to 30 seconds. The `nginx.conf` and `apache.conf` that ship with
the deploy stack, and the servers' own defaults, allow 60; a proxy or load
balancer with a shorter read or idle timeout in front of the gateway must be
raised to at least 30 seconds, plus a margin. See [Scaling](scaling.md#the-event-feed).

**Rolling back.** The undo scripts for 0.4.59 say to roll the gateway,
scheduler, ingestor and worker back to 0.4.58 first. The undo of the outbox
columns needs the worker and gateway rolled back first, and voids every feed
cursor ever handed out; clients start again from a fresh cursor. See
[Rolling back the schema](#rolling-back-the-schema).

## API keys and the key-authenticated API (0.4.49–0.4.50)

Release 0.4.49 makes API keys a working credential and opens the
[key-authenticated API](../guide/api.md) at `/api/public/v1`; release 0.4.50
fills it with the resource endpoints and serves its description at
`/api/openapi/public/v1.json`. Keys are now created by each member for
themselves under **My account → API keys**, and act as that member. That tab
ships in dashboard 0.2.38; upgrade the dashboard to it together with the
backend. Upgrade straight to 0.4.50: on 0.4.49 alone the key dialog's link to
the API description leads nowhere.

**Every existing API key is revoked by the migration.** The rows written before
this release hold hashes that can never be matched — no earlier build ever
authenticated a request with one — so the migration marks every one of them
revoked rather than list them as usable. They stay visible as revoked until
someone deletes them, and until then they count against the key limit of the
member who created them — an administrator who created keys for several
pipelines may already be at the limit. Tell anyone who holds a key to create a
new one under **My account → API keys** after the upgrade; there is nothing to
convert. The revoked leftovers are deleted by the member who created them,
under **My account → API keys**, or by anyone with Settings Write, under
**Settings → API keys**.

**The new environment variables are optional.** The gateway reads
`RATE_LIMIT_API_MAX` / `RATE_LIMIT_API_WINDOW` (300 requests per 60 seconds per
key), `RATE_LIMIT_API_FAILURE_MAX` / `RATE_LIMIT_API_FAILURE_WINDOW` (30 requests per
60 seconds per address whose token names no key, or that carry none) and `MAX_API_KEYS_PER_USER` (20). The
defaults apply when they are unset; `docker/deploy/.env.example` carries them
commented out. See [Configuration](../install/configuration.md#security) and
[API keys](../install/configuration.md#api-keys).

**Let the new paths through your proxy.** If the web server in front of the
gateway passes only an allowlist of paths, add `/api/public/` for the API and
`/api/openapi/` for its description. A stack that forwards all of `/api/` needs
nothing.

**The schema changes.** Three migrations: 0.4.49 adds two columns and two indexes to
`api_keys`, and one nullable column to `org_audit_log`; 0.4.50 removes
duplicate webhook bindings — two bindings of the same webhook to the same
resource, which fired it twice — keeping the oldest, and adds a unique index so
they cannot recur. The undo of that last one does not bring the duplicates
back. There is no other backfill beyond the key revocation above.

!!! warning "A rollback revokes every key"
    The undo script for the key migration revokes every key, including ones
    created after the upgrade. Rolling back and forward again therefore means
    everyone creates their keys again. The undo of the audit-log column folds
    each entry's key id into its comment first, so the log keeps saying which
    key an action came through. See
    [Rolling back the schema](#rolling-back-the-schema).

## Response body retention (0.4.35)

Release 0.4.35 gives saved response bodies a retention window of their own.
The aggregate-worker reads `BODY_RETENTION_DAYS` (`worker.bodyRetentionDays`)
alongside `RESULT_RETENTION_DAYS`, and it defaults to `-1` — the window is off
unless you turn it on. The upgrade therefore changes nothing, whatever your
result window is: the worker's body pass does not run, and bodies go out with
their results exactly as they did before. The bundled Compose files and
`docker/deploy/.env.example` do not set the variable; they carry a commented
line next to `RESULT_RETENTION_DAYS` showing how.

The reason to set it is that bodies are the expensive half of a result.
`BODY_RETENTION_DAYS=7` against a 90-day result window sheds the megabytes after
a week and keeps three months of timings, assertions and status. The window
cannot extend a body's life — a body never outlives its result — so a value
above `RESULT_RETENTION_DAYS` does nothing, and `-1` means "do not expire bodies
by age", not "keep them forever". See
[Retention & Aggregation](retention.md#results-and-bodies-age-separately).

**Check for a `0` first.** Both probe-data windows now read `> 0` as days and
any negative value as "never expire by age", and `0` is refused rather than
treated as a synonym for `-1`: the worker fails configuration load with
`BODY_RETENTION_DAYS must not be 0 — use -1 to never expire by age, or a
positive number of days` (and the same for `RESULT_RETENTION_DAYS`) and the
container exits before any job runs. If an older install set
`RESULT_RETENTION_DAYS=0` to mean "keep forever", change it to `-1` in both the
gateway and the worker before you upgrade, or the worker will not start.

A body the new pass expires records `bodyExpired` as the reason it is
unavailable. The result page shows that where the body would be, under the
heading **Body no longer stored** rather than "Body not stored" — the same
heading `storeRemoved` gets, because in both cases the body was saved and has
gone since, which is not the same story as a body that was never kept. The
result itself is intact. Nothing needs backfilling: the pass starts on the next
retention tick after you set a window.

!!! tip "Pre-build the index by hand on a large `probe_steps`"
    The release adds one index, `idx_probe_steps_expirable_body` — a partial
    index on `probe_steps (probe_result_id)` covering only the rows that carry a
    platform-owned body — and the migration creates it as a plain
    `CREATE INDEX IF NOT EXISTS`. It cannot say `CONCURRENTLY`: Flyway holds an
    advisory lock inside a transaction for the whole run, and
    `CREATE INDEX CONCURRENTLY` waits for every transaction that can see the
    table to finish, including Flyway's own — it would not fail, it would hang.

    A plain build takes a `SHARE` lock on `probe_steps` for the length of the
    scan, and `probe_steps` is the largest table in the schema. On a small
    install that is seconds. On a big one it blocks result ingestion for as long
    as it takes, and since the migrator gates the whole stack, the upgrade waits
    with it.

    If your `probe_steps` is large, build the index by hand against the running
    old release *before* you deploy 0.4.35:

    ```sql
    CREATE INDEX CONCURRENTLY idx_probe_steps_expirable_body
        ON probe_steps (probe_result_id)
        WHERE response_body_storage_url IS NOT NULL AND body_store_id IS NULL;
    ```

    `IF NOT EXISTS` then makes the migration a no-op and the upgrade is as quick
    as any other. Check it finished valid before deploying — a cancelled
    `CONCURRENTLY` build leaves an invalid index behind, which the migration will
    happily skip:

    ```sql
    SELECT indisvalid FROM pg_index
     WHERE indexrelid = 'idx_probe_steps_expirable_body'::regclass;
    ```

    If that returns `f`, `DROP INDEX idx_probe_steps_expirable_body;` and build
    it again.

## Body stores (0.4.33)

Release 0.4.33 adds [body stores](body-stores.md) — locations other than the
platform's own storage that named agents keep saved response bodies in. An
existing install is unaffected until you create one: with no stores, bodies go
exactly where they went before. Three things are still worth doing at the
upgrade rather than after it.

**Give the aggregate-worker its bucket and prefix.** The worker now deletes only
inside the location it is configured with — `STORAGE_S3_BUCKET` plus
`STORAGE_S3_PREFIX` for S3, `STORAGE_FILESYSTEM_ROOT` for disk. Set them to the
same values result-ingestor has. A worker whose bucket or prefix does *not*
match the ingestor's is the case to avoid: it skips every body outside its own
fence rather than deleting it, logging them at WARN with a count per run, and
the objects accrue with nothing pointing at them. An install that set
`STORAGE_S3_ENDPOINT` on the worker and no bucket — which is all this
documentation previously asked for — keeps the old unconfined behaviour and
says so at startup with a WARN, so the upgrade does not silently stop deleting.
See [Body storage](../install/configuration.md#body-storage).

**Add `BODY_STORE_AES_KEY` before you create your first store.** Body-store
credentials are encrypted under a key of their own, shared by api-gateway and
result-ingestor, with no default and no placeholder. It is not needed to
upgrade; it is needed before the first store is saved. Generate it with
`openssl rand -hex 32` — see
[Secrets & Encryption](secrets.md#body_store_aes_key).

**Nothing else.** The migrations add one table and three nullable columns. There
is no backfill, and no downtime beyond the ordinary migrator run.

!!! danger "Do not roll the schema back past 0.4.33 once an `in_place` store holds bodies"
    `probe_steps.body_store_id` is the only record of which bodies live outside
    the default store. Its undo script clears the stored URL on every step that
    carries one before dropping the column, so rolling back turns every
    `in_place` body into "not stored" — permanently, and for bodies the platform
    never had a copy of. The objects survive in the store; nothing in Tracedown
    knows where they are any more.

    The two undo scripts also have an order between them:
    `probe_steps.body_store_id` references `body_stores(id)`, so the
    result-ingestor's undo has to run before the gateway's. If you have to go
    back, restore the backup you took before the upgrade instead. See
    [Rolling back the schema](#rolling-back-the-schema).

## Moving to PostgreSQL 18

Release 0.4.0 moved every bundled stack — the development and deploy Compose
files, the installer's monolith and Kubernetes modes, the end-to-end stack —
from `postgres:16-alpine` to `postgres:18-alpine`. A volume that an earlier
release initialised holds a PostgreSQL 16 cluster, and PostgreSQL 18 cannot
open it: the container refuses to start (see
[Troubleshooting](troubleshooting.md#postgres-will-not-start-there-appears-to-be-postgresql-data-in))
rather than initialising an empty database beside your data. The move is a
dump with the old version and a restore into the new one. The schema is plain
SQL, so the dump needs no editing.

Two things changed in the Compose file itself, in case you maintain your own:
the image tag, and the mount point. The 18 images keep the cluster at
`/var/lib/postgresql/18/docker`, so the volume now mounts the parent,
`/var/lib/postgresql`, instead of `/var/lib/postgresql/data`.

1. With the old stack still running, dump the database and confirm the dump
   reads back:

    ```bash
    docker compose exec -T tracedown-postgres \
      pg_dump -U tracedown -d tracedown -Fc > pre-18.dump
    pg_restore -l pre-18.dump | head
    ```

2. Stop the stack, pull the release, and remove the old volume. This is the
   irreversible step — do it only once the dump above is verified and copied
   somewhere safe:

    ```bash
    docker compose down
    git pull
    docker volume rm tracedown_tracedown-pgdata   # confirm the name: docker volume ls
    ```

3. Start only the database, so it initialises an empty 18 cluster, and restore
   into it **before** the migrator runs — the dump already contains the schema
   and `flyway_schema_history`:

    ```bash
    docker compose up -d --wait tracedown-postgres
    docker compose exec -T tracedown-postgres \
      pg_restore -U tracedown -d tracedown --no-owner < pre-18.dump
    ```

4. Bring up the rest. The migrator finds the history table, applies whatever
   the new release adds on top, and the services start:

    ```bash
    docker compose up -d
    docker compose logs tracedown-migrator
    ```

The installer's monolith and Kubernetes modes follow the same shape with their
own volume (`pgdata`, or the `tracedown-pgdata` claim) and service name
(`postgres`). A managed instance — Railway, RDS and the like — upgrades with
the provider's own major-version tooling instead; nothing on Tracedown's side
changes. Backups in general are covered in [Backup & Restore](backup.md).

## Rolling back the schema

Migrations that are not part of the initial schema ship with an undo script — a
`U<epoch>__` file beside each `V<epoch>__` file, created as a pair by
`new-migration.sh`.

!!! warning "The undo scripts exist, but nothing runs them for you"
    Tracedown ships no command that applies undo scripts. The migrator only
    calls Flyway's `migrate`. The scripts are there so that a rollback is
    *possible* — you apply them yourself against the database and reconcile
    `flyway_schema_history` accordingly. Treat this as a manual recovery
    procedure, not a supported rollback button, and restore from backup instead
    unless you have a specific reason not to.

## Upgrading agents

Agents are not compose-managed, so they upgrade separately: rebuild the agent
image and restart the container.

!!! tip "A restarted agent keeps its identity"
    Bootstrap is skipped when the certificate and key files already exist. An
    upgraded agent that keeps its cert volume therefore reuses its existing
    identity and does **not** need re-enrolling — no new bootstrap token, no
    re-registration. Preserve the volume and the upgrade is just a restart.

The corollary is that losing the cert volume *does* mean re-enrolling. See
[Probe Agents](../install/agents.md) and
[Certificate Authority](certificate-authority.md).
