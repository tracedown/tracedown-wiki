---
description: "Tracedown runs on stock PostgreSQL 16 with no extensions and no hypertables. How the Flyway schema-migrator applies, orders and undoes schema migrations."
---
# Database & Migrations

Tracedown stores everything in a single PostgreSQL 16 database. Schema changes
are applied by Flyway, run by a dedicated service called `schema-migrator` that
does one job and exits.

## PostgreSQL

| Property | Value |
|---|---|
| Version | 16 |
| Extensions | **None required** |
| Hypertables | **None** |

The schema is plain PostgreSQL. No `CREATE EXTENSION`, no `create_hypertable`,
nothing that ties you to a particular distribution — any stock PostgreSQL 16
works, whether that is a container, a package, or a managed instance.

Every stack in the repository — development Compose, the deploy Compose and the
end-to-end test stack — runs `postgres:16-alpine` against these same migrations.

!!! warning "Raise `max_connections` to 160"
    The one setting Tracedown needs that a stock PostgreSQL does not give you.
    The service pools reserve **103** connections while idle, above PostgreSQL's
    default of 100, and a stack that cannot get its connections does not boot —
    services fail to acquire and exit. The bundled Compose files start the
    database with `postgres -c max_connections=160`; a database you supply
    yourself needs the same, set in `postgresql.conf` or on the command line.
    The connection budget is worked through in
    [Scaling](../admin/scaling.md#database-connections).

### Connection semantics

Every application service builds its pool through the same factory (the
one-shot migrator manages its own connection), which sets:

- `isAutoCommit = false`
- `transactionIsolation = TRANSACTION_REPEATABLE_READ`

Repeatable read is deliberate. The transactional outbox pattern depends on
writes and their outbox rows committing atomically and being read consistently;
at read committed, a consumer can observe a partial view within a transaction.
The cost is that concurrent writers can hit serialisation failures under
contention, which the services are written to expect.

## The migrator

Migrations run in a dedicated service rather than inside the application
services at startup. This is the important design decision on this page.

An app service that migrates on boot is fine with one replica and a race with
two: N replicas starting together all try to migrate the same database at once.
Flyway locks, so the outcome is usually survivable rather than corrupt — but
"usually" is doing real work in that sentence, and startup ordering becomes
something you have to reason about on every deploy. A separate service that runs
to completion *before* any app service starts removes the question entirely.

The corollary is that there is exactly **one** `flyway_schema_history` table for
the whole platform, even though each service module owns its own migration
files. The schema is one schema; the modules are just where the files live.

### Configuration

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `DATABASE_URL` | JDBC URL | *(none)* | **Yes** |
| `DATABASE_USER` | Database user | *(none)* | **Yes** |
| `DATABASE_PASSWORD` | Database password | *(none)* | **Yes** |
| `FLYWAY_LOCATIONS` | Comma-separated Flyway locations | *(see below)* | No |

All three connection variables are hard requirements — the migrator errors out
immediately rather than falling back to a default, on the grounds that silently
migrating the wrong database is worse than not starting.

By default it scans two classpath locations:

```
classpath:db/initial_schema
classpath:db/migrations
```

!!! warning "`FLYWAY_LOCATIONS` replaces, it does not extend"
    Setting `FLYWAY_LOCATIONS` **clears** the defaults and uses only what you
    provide. It does not append. If you set it to add a location, include both
    built-in locations or the base schema will not be applied.

### Startup and exit

The migrator retries the database connection **30 times at 2-second intervals**
before giving up — roughly a minute, which covers a Postgres container that is
still initialising. It exits `0` on success and `1` on failure, making it usable
as a gate in any orchestrator that understands exit codes.

### Running it

=== "Docker Compose"

    The stack defines it as `tracedown-migrator`, and every service that
    touches the database gates on it (email-service, which has no database,
    gates only on Redis):

    ```yaml
    depends_on:
      tracedown-migrator:
        condition: service_completed_successfully
    ```

    `service_completed_successfully` is what makes this work — Compose waits for
    the container to exit `0` before starting anything that depends on it. A
    failed migration means the app services never start, which is the correct
    outcome. Nothing else is needed; `docker compose up` migrates first.

=== "Standalone"

    ```bash
    export DATABASE_URL=jdbc:postgresql://localhost:5432/tracedown
    export DATABASE_USER=tracedown
    export DATABASE_PASSWORD=...

    ./bin/schema-migrator
    ```

    The launcher comes from Gradle's `installDist` output
    (`schema-migrator/build/install/schema-migrator/`), which is what the
    shipped image runs.

!!! warning "Use the installDist launcher, not a merged JAR"
    The migrator is deliberately distributed via `installDist` rather than as a
    fat JAR. Flyway 11's classpath scanning does not reliably find migration
    resources inside a merged JAR, so a fat-JAR build can connect, find zero
    migrations, and report success having applied nothing. That failure is
    silent and looks like a working run. Run `./bin/schema-migrator` with its
    `lib/` directory intact.

## How migrations are organised

Six modules are wired to own migrations (probe-scheduler currently ships none).
The `schema-migrator` Gradle build copies each
module's `src/main/resources/db` onto a single classpath with
`DuplicatesStrategy.FAIL`, so a filename collision between two modules breaks
the build rather than letting one silently overwrite the other.

Each module has a version prefix:

| Module | Prefix |
|---|---|
| api-gateway | `1` |
| probe-scheduler | `2` |
| result-ingestor | `3` |
| notification-dispatcher | `4` |
| metrics-service | `5` |
| aggregate-worker | `6` |

### Initial schema

Files in `db/initial_schema/` are named `V<prefix>_NNN__<description>.sql`:

```
api-gateway/src/main/resources/db/initial_schema/V1_001__create_users.sql
aggregate-worker/src/main/resources/db/initial_schema/V6_001__create_probe_aggregates.sql
```

The prefix keeps modules from colliding while letting each number its own tables
from `001`. These represent the base schema and are not modified after release.

### Later migrations

Files in `db/migrations/` use a bare epoch timestamp — that is,
`V<epoch>__<description>.sql`:

```
result-ingestor/src/main/resources/db/migrations/V1783694803__probe_results_nullable_agent_for_skipped.sql
```

No module prefix — that is the point. Once the platform is live, a migration's
correct position in the order depends on *when it was written*, not which module
wrote it. A scheduler migration authored on Tuesday must run after a gateway
migration authored on Monday, because the second may depend on the first. Epoch
versions order globally across modules and give that for free; module-prefixed
versions would interleave wrongly.

### Undo scripts

Every non-initial migration requires a matching undo script, `U<epoch>__` with
the same epoch and description:

```
V1783694803__probe_results_nullable_agent_for_skipped.sql
U1783694803__probe_results_nullable_agent_for_skipped.sql
```

### Creating a migration

Use the helper — it stamps the epoch and creates both halves of the pair:

```bash
./new-migration.sh <module> <description>
```

```bash
./new-migration.sh api-gateway add_totp_columns_to_users
```

It lives at `core/tracedown-core-backend/new-migration.sh` and validates the
module name against the six above. Writing the files by hand is possible but
invites a mismatched epoch between the forward and undo scripts, which is
tedious to unpick later.

## Related

- [Backup & Restore](../admin/backup.md) — dump and restore procedure.
- [Upgrading](../admin/upgrading.md) — where migrations fit in an upgrade.
- [Configuration](configuration.md) — connection variables and pool sizing.
- [Scaling](../admin/scaling.md) — the connection budget across replicas.
