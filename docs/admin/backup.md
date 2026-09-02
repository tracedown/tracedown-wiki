---
description: "Backing up self-hosted Tracedown is pg_dump plus PLATFORM_AES_KEY, stored apart from each other. What to back up, what to skip, and how to restore it."
---
# Backup & Restore

Tracedown has no built-in backup scheduler, no snapshot command, and no restore
wizard. What it has is a PostgreSQL database and a few Docker volumes, which
means backing it up is ordinary Postgres and volume operations that your
existing tooling almost certainly already does. This page tells you what to
point that tooling at, and — more importantly — what has to survive alongside
the database for a restore to produce a working system.

!!! danger "The database is not a complete backup by itself"
    `PLATFORM_AES_KEY` is not stored in the database. A `pg_dump` without the
    key restores into a system that cannot decrypt its own variables, TOTP
    secrets, or CA private key. This is the single most important point on this
    page and the rest of it assumes you have taken it seriously.

## What to back up

| Item | Where | Priority | Losing it costs you |
|---|---|---|---|
| PostgreSQL | volume `tracedown-pgdata` | Critical | Everything. System of record. |
| `PLATFORM_AES_KEY` | your secrets store | Critical | The ability to read the backup at all. |
| Redis A | volume `tracedown-redis-a-data` | Worthwhile | In-flight results, queued emails, notifications. |
| Saved bodies | volume `tracedown-bodies` or your bucket | Situational | Stored response bodies. |
| Redis B / C | — | **Do not back up** | Nothing. Pure cache; rebuilds. |

### PostgreSQL — the system of record

Everything durable lives here: orgs, projects, services, probe scripts, probe
results, aggregates, users, the outbox, and the encrypted CA root. If you back
up exactly one thing, this is it.

The development stack publishes Postgres on host port **5555** (container
`tracedown-postgres`, mapped from 5432), with database and user both defaulting
to `tracedown`:

=== "From the host"

    ```bash
    pg_dump -h localhost -p 5555 -U tracedown -d tracedown -Fc \
      -f tracedown-$(date +%F).dump
    ```

=== "Through the container"

    ```bash
    docker exec -t tracedown-postgres \
      pg_dump -U tracedown -d tracedown -Fc > tracedown-$(date +%F).dump
    ```

The custom format (`-Fc`) is worth the habit — it compresses and it restores
with `pg_restore -j` in parallel, which matters once probe results have
accumulated.

!!! note "Check your own values"
    `DB_NAME`, `DB_USER`, `DB_PASSWORD` and the published port come from
    `docker/.env` and `docker/docker-compose.yml`. The values above are the
    shipped development defaults. If you changed them — and per
    [Secrets & Encryption](secrets.md) you should have changed the password —
    use yours.

The schema uses no extensions and no hypertables, so a dump restores into any
stock PostgreSQL 18 — a container, a distro package or a managed instance —
without ceremony. The one thing the restore target needs is
`max_connections` at 160 or above before you point the stack at it. See
[Database & Migrations](../install/database.md).

### PLATFORM_AES_KEY — back it up separately

The CA root private key lives in the `ca_root` table, encrypted with
`PLATFORM_AES_KEY`. So do every org, workspace, project and service variable
(secret variables via their org's data-encryption key, which the platform key
wraps — see [Secrets & Encryption](secrets.md#envelope-encryption-for-secret-variables)),
and every TOTP secret. The key itself is only ever an environment variable.

One consequence worth knowing: deleting an organization crypto-shreds its
secrets by destroying its data-encryption key in the live database — but a
backup taken before the deletion still holds both the wrapped key and the
ciphertexts. Erasure is only as complete as your backup retention window.

Two failure modes follow, and they pull in opposite directions:

- **Backup without the key.** The dump restores, the schema is intact, and the
  data is noise. Variables cannot be decrypted, 2FA users cannot log in, and
  the scheduler cannot sign agent certificates — every agent must be
  re-bootstrapped, and even that does not recover the variables.
- **Backup stored *with* the key.** Whoever takes the backup gets both halves,
  and the encryption bought you nothing.

So the key goes somewhere durable and *separate*: a password manager, a secrets
manager, an offline copy in a safe. Not next to the dumps. Moving to a new key
is possible while you still hold the old one —
[partly by command, partly by hand](secrets.md#re-keying-an-installation-that-already-holds-data)
— but that is a rotation path, not a recovery path. Losing the key is not an
incident you recover from; it is a rebuild.

### Redis A — worth backing up, not catastrophic

Redis A is the operational instance: the probe-result queue, the email queues,
the outbox nudges, health-challenge tokens, and the scheduler's dispatch locks.
It runs with `--appendonly yes` and persists to the `tracedown-redis-a-data`
volume, so it survives restarts on its own.

Losing it drops what was in flight at that moment — probe results queued but not
yet ingested, emails and notifications not yet delivered. It does not lose
history, because anything already ingested is in Postgres, and it does not log
anyone out — sessions live in Postgres too. Back it up if it is cheap to do so;
do not lose sleep over the gap between snapshots.

### Saved response bodies

The `tracedown-bodies` volume is mounted at `/data/bodies` and shared between
the gateway and the agent. Bodies are diagnostic detail attached to probe
steps, not system-of-record data, so whether they are worth backing up depends
entirely on whether you would miss them.

If `PROBE_AGENT_STORAGE_BACKEND=s3`, bodies live in your bucket instead and the
volume is irrelevant — back up the bucket by whatever means it offers, or
accept its durability. In that configuration the aggregate-worker needs
`STORAGE_S3_*` credentials to delete bodies when results age out; see
[Retention & Aggregation](retention.md).

### Redis B and C — do not back up

Pure cache: rate-limit counters, the percentile cache the hourly aggregation job
populates, resource-hierarchy lookups. They rebuild from Postgres on demand.
Backing them up costs storage and buys nothing, and restoring a stale cache is
strictly worse than starting with an empty one.

## Restoring

Order matters, and the reason is the encryption key rather than anything
Tracedown does at startup.

1. **Restore PostgreSQL** into an empty database.

    ```bash
    pg_restore -h localhost -p 5555 -U tracedown -d tracedown \
      --clean --if-exists -j 4 tracedown-2026-07-16.dump
    ```

2. **Set `PLATFORM_AES_KEY` to the value in force when the data was written.**
   Not a fresh key, not the default. If you cannot produce that exact value,
   stop — the restore will appear to succeed and the data will be unreadable.
   Confirm the same value reaches api-gateway, probe-scheduler, and
   notification-dispatcher.

3. **Start the stack.** The migrator runs first and is idempotent: it applies
   any migrations the dump predates and does nothing when the schema is already
   current, so it is safe against a same-version restore. See
   [Database & Migrations](../install/database.md).

4. **Verify before trusting it.** Log in, open a service with variables and
   confirm they resolve, and check that a probe actually dispatches. A probe
   run exercises variable decryption and the CA path together, which is the
   fastest way to prove the key matches. If agents fail to receive work, read
   [Certificate Authority](certificate-authority.md).

!!! tip "Restore drills are the only way to know"
    A backup you have never restored is a hypothesis. The specific thing to
    rehearse is not `pg_restore` — it is whether you can lay hands on
    `PLATFORM_AES_KEY` under pressure, months after whoever generated it set it
    and moved on.

## There is no built-in scheduler

Nothing in Tracedown takes periodic backups for you. This is deliberate rather
than missing: the data is in PostgreSQL and Docker volumes, both of which have
decades of mature tooling, and a bespoke scheduler inside the application would
be a worse version of `cron` plus `pg_dump`, or of whatever your platform
already provides. Use those.

The only Tracedown-specific requirement is the one at the top of this page: the
encryption key must be backed up too, and somewhere else.

## Related

- [Secrets & Encryption](secrets.md) — what the key protects, and how far it can be re-keyed.
- [Database & Migrations](../install/database.md) — how the migrator behaves.
- [Certificate Authority](certificate-authority.md) — the CA root in `ca_root`.
- [Retention & Aggregation](retention.md) — what is deleted automatically.
- [Upgrading](upgrading.md) — back up before you upgrade.
