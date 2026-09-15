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
