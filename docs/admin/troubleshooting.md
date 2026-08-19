# Troubleshooting

Known failure modes, each as cause and fix. They are grouped by when you hit
them: standing the stack up, enrolling agents, and running in production.

## Installation and startup

### The stack will not come up on a small host

Services start, fail to acquire database connections, and exit. Nothing reaches
a healthy state.

**Cause.** `timescaledb-tune` runs at initdb and derives `max_connections` from
available host memory. On a small host it lands below what the connection pools
need. Eight JVM services at the default pool size of 10 want 80 connections, and
HikariCP fills its pool to maximum eagerly rather than on demand — so the demand
is immediate and permanent, not gradual.

**Fix.** Set `TS_TUNE_MAX_CONNS: "100"` on the Postgres container, as the
bundled compose does. Because it applies at initdb, it has no effect on an
existing data volume — you need a fresh volume or a manual `max_connections`
change. Alternatively, lower `DB_POOL_SIZE`.

!!! warning "`DB_POOL_SIZE` does not apply everywhere"
    aggregate-worker, metrics-service and realtime-service pass
    `maximumPoolSize = 5` in code, which overrides the environment variable.
    Their pools are 5 whatever you set. Count them as 5 each when budgeting.

See [Scaling](scaling.md).

### The Docker build fails at a COPY step

**Cause.** The backend's Docker build context is the **parent** of the
repository root, so the repository must sit at `core/tracedown-core-backend`
inside a containing directory. Cloned anywhere else, the build fails with a
"not found" error at the first COPY step.

**Fix.** Clone into the tree shown in
[Requirements](../install/requirements.md#source-layout).

### realtime-service will not start

**Cause.** Its `DATABASE_URL`, `DATABASE_USER`, `DATABASE_PASSWORD` and
`REDIS_A_URL` are mandatory HOCON substitutions with **no defaults**. A missing
one fails config resolution at startup rather than degrading at runtime.

**Fix.** Set all four. See [Configuration](../install/configuration.md).

## Agents and certificates

### An agent registers but never receives work

The agent is up, enrolled, and idle.

**Cause.** The scheduler **dials** the agent — the agent does not poll for work.
It must therefore be reachable *inbound* from the scheduler. An agent behind NAT
with no inbound route registers successfully and then never hears from anyone,
which is why this looks like a scheduling bug rather than a networking one.

**Fix.** Give the scheduler a route to the agent's URI. Also confirm the agent
is active and passing health challenges — see
[Monitoring Tracedown](observability.md) and
[Probe Agents](../install/agents.md).

### "CA root not initialized — run --agent-bootstrap first"

**Cause.** No active CA row exists in the database.

**Fix.** Run `--agent-bootstrap`, which creates it. This is exactly what the
compose `tracedown-ca-init` step does:

```bash
./bin/api-gateway --agent-bootstrap <agent-slug>
```

See [Certificate Authority](certificate-authority.md).

### A bootstrap token is rejected

**Cause.** Tokens are **single-use** with a **1 hour TTL**. A reused or stale
token is refused.

**Fix.** Generate a fresh one with `--agent-bootstrap`.

### Agent renewal skipped with an unknown-slug warning

**Cause.** The agent cannot determine its own slug. It is normally persisted at
`/certs/agent-slug.txt`; if that file is absent — typically a lost or recreated
cert volume — renewal has nothing to renew against and skips.

**Fix.** Set `PROBE_AGENT_SLUG` explicitly.

### Variables decrypt as garbage, or agent mTLS fails after a config change

**Cause.** `PLATFORM_AES_KEY` differs between api-gateway, probe-scheduler and
notification-dispatcher. All three must share the **exact same value** — the
gateway encrypts, the other two decrypt. The dispatcher needs it for org
variables referenced from webhook URLs.

**Fix.** Make the value identical across all three. Note that data encrypted
under a previous key is not recoverable by setting a new one — see
[Secrets & Encryption](secrets.md).

## Running

### Probes are reported as skipped, or over capacity

Users see runs marked `skipped`, and a `dispatch_capacity` banner appears.

**Cause.** Either the dispatch queue overflowed (`SCHEDULER_DISPATCH_QUEUE_SIZE`,
default `100000` — it must exceed your largest per-tick fleet), or a service's
next tick came due while its previous tick was still waiting in the queue.
Both are capacity sheds; a run suppressed by the service's queue policy is
dropped silently and does not appear as `skipped`.

**Fix.** For overflow, raise the queue size — entries are tiny. For sustained
capacity pressure, **add agents**. Resist raising
`SCHEDULER_DISPATCH_WORKERS`: it is the global backpressure limit, and raising
it risks congestion collapse against slow targets. See [Scaling](scaling.md).

### Aggregation or retention work is duplicated

**Cause.** More than one aggregate-worker replica is running. It has no
distributed lock — its jobs are plain coroutine loops that assume they are
alone.

**Fix.** Run exactly one replica. See [Retention & Aggregation](retention.md).

### Emails are not sent

**Cause, the common one.** `EMAIL_PROVIDER` defaults to `console`, which only
logs the message.

**Cause, the subtle one.** The api-gateway and email-service use **different
variable names for the same provider settings**. Configuring one leaves the
other on `console`, so some mail sends and some does not:

| Setting | api-gateway | email-service |
|---|---|---|
| SMTP host | `SMTP_HOST` | `EMAIL_SMTP_HOST` |
| SMTP port | `SMTP_PORT` | `EMAIL_SMTP_PORT` |
| SMTP username | `SMTP_USERNAME` | `EMAIL_SMTP_USERNAME` |
| SMTP password | `SMTP_PASSWORD` | `EMAIL_SMTP_PASSWORD` |
| SMTP TLS mode | `SMTP_TLS_MODE` | `EMAIL_SMTP_TLS_MODE` |
| Resend API key | `RESEND_API_KEY` | `EMAIL_RESEND_API_KEY` |
| Mailgun API key | `MAILGUN_API_KEY` | `EMAIL_MAILGUN_API_KEY` |
| Mailgun domain | `MAILGUN_DOMAIN` | `EMAIL_MAILGUN_DOMAIN` |
| Mailgun region | `MAILGUN_REGION` | `EMAIL_MAILGUN_REGION` |

**Fix.** Set `EMAIL_PROVIDER` on both services, and configure both naming sets.
See [Configuration](../install/configuration.md).

### The usage window is shorter than expected

**Cause.** `RESULT_RETENTION_DAYS` caps it — you cannot display history that has
been deleted. The gateway's value must match the aggregate-worker's, or the
dashboard advertises a window the worker has already pruned.

**Fix.** Set `RESULT_RETENTION_DAYS` identically on both. See
[Retention & Aggregation](retention.md).

### Probes against a domain are limited to 3 calls, save no bodies, and run no more than every 5 minutes

**Cause.** `TRUSTED_DOMAIN_MODE` is `false` and the target domain is unverified.
The anti-abuse policy then caps the script at 3 calls, disables body saving, and
enforces a 5-minute minimum interval. Scripts exceeding the call limit are
skipped outright.

**Fix.** Verify the domain (Settings → Domains), or set `TRUSTED_DOMAIN_MODE=true`
if every target is one you control — this turns the ownership checks off.
Verification is the default; it signals good-faith use of the platform. See the
[User Manual](../guide/index.md) and
[Configuration](../install/configuration.md).
