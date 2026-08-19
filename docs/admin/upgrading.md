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
