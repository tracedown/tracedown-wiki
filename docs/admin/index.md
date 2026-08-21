---
description: "Operating a self-hosted Tracedown install: secrets and encryption, the certificate authority, backup and restore, retention, scaling, monitoring and upgrades."
---
# Administration

The [Installation](../install/index.md) section gets Tracedown running. This
section is about what you deal with once it is real: once it holds data you
cannot regenerate, once other people depend on it being up, and once the
placeholder secrets you copied from the shipped `.env.example` have become a
liability rather than a convenience. Nothing here is required to evaluate Tracedown. All of it is
required to operate it.

If you are moving a trial installation toward something people rely on, read
[Secrets & Encryption](secrets.md) first and
[Backup & Restore](backup.md) second. Those two pages cover the failures that
are unrecoverable; everything else on this list can be fixed after the fact.

## The pages

| Page | Read this when… |
|---|---|
| [Secrets & Encryption](secrets.md) | Before you expose the install to anyone. Covers `PLATFORM_AES_KEY`, `JWT_SECRET`, the shipped development values, and what can and cannot be rotated. |
| [Certificate Authority](certificate-authority.md) | You are enrolling agents, an agent certificate is expiring, or you need to understand the CA that underpins scheduler↔agent mTLS. |
| [Backup & Restore](backup.md) | Before you have data worth losing. The encryption key and the database must both survive, and they must be backed up separately. |
| [Retention & Aggregation](retention.md) | Your database is growing, you want longer history, or you are deciding how many aggregate-worker replicas to run. |
| [Scaling](scaling.md) | Probes are queuing, one host is no longer enough, or you need to know which services can run more than one replica. |
| [Monitoring Tracedown](observability.md) | You want Tracedown's own health in Prometheus or Grafana — the monitoring system needs monitoring too. |
| [Upgrading](upgrading.md) | You are moving to a new version and want to know the migration and ordering rules. |
| [Troubleshooting](troubleshooting.md) | Something is wrong and you want the symptom-to-cause map rather than a tour of the architecture. |
