# Installation

Tracedown ships in two forms, and there are three ways to run it:

| Path | What it is | Use it when |
|---|---|---|
| **[Quickstart (Docker)](quickstart.md)** | The development Compose stack, built from source. | Trying Tracedown out, or developing it. |
| **[Production Deploy](deploy.md)** | The full per-service stack, pulled from published release artifacts, fronted by your own web server. | Running it for real, with probe agents where you need them. |
| **[Monolith](monolith.md)** | The entire platform in a single jar — one process, dashboard included, probes executed in-process. | Small installs that don't want eight services. |

The per-service form is a set of JVM services, a Python probe agent,
PostgreSQL, and Redis. The monolith is those same services in one JVM, needing
only PostgreSQL and Redis. Both are the complete product — the difference is
operational shape, and [Monolith](monolith.md) is candid about the trade.

Read these in order:

1. **[Requirements](requirements.md)** — what you need before you start.
2. **[Quickstart (Docker)](quickstart.md)** — a running system in a few minutes.
3. **[Production Deploy](deploy.md)** — the release-artifact stack behind your web server.
4. **[Monolith](monolith.md)** — the single-jar edition.
5. **[Architecture](architecture.md)** — what the services are and how they talk.
6. **[Configuration](configuration.md)** — the full environment-variable reference.
7. **[Database & Migrations](database.md)** — how schema changes are applied.
8. **[Probe Agents](agents.md)** — deploying agents and enrolling them over mTLS.

!!! warning "The development stack ships with development secrets"
    The Quickstart's `.env.example` contains a placeholder encryption key, a
    placeholder JWT secret, and a known demo password. They are fine for a
    local trial and unacceptable for anything reachable by other people. The
    [Production Deploy](deploy.md) refuses to start on placeholder secrets;
    before you expose anything to a network, work through
    **[Secrets & Encryption](../admin/secrets.md)**.

## Which pieces are optional

| Piece | Needed? |
|---|---|
| PostgreSQL | Required. System of record. |
| Redis A | Required. Queues, outbox, sessions — persistent (AOF). |
| Redis B | Required in practice. Cache and rate limiting; safe to lose. |
| Redis C | Optional. Resource-hierarchy cache; disabled when `REDIS_C_URL` is empty. |
| Probe agent | Required in the per-service stack — nothing probes without at least one. The [monolith](monolith.md) executes probes in-process and uses no agents. |
| S3-compatible storage | Optional. Only if you want saved response bodies off local disk. |
| SMTP / Resend / Mailgun | Optional, but without it no email leaves the system. |

## After installation

Once the stack is up — and, in the per-service form, an agent is enrolled —
the **[User Manual](../guide/index.md)** covers creating your first service and
probe. The **[Administration](../admin/index.md)** section covers the things
you only think about once it is real: backups, certificate rotation,
retention, and scaling.
