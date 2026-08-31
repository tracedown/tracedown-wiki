---
description: "Tracedown failure modes with cause and fix: the stack not starting on a small host, Docker build COPY errors, agent enrolment and certificates, emails not sent."
---
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

### An agent refuses to enrol: "could not authenticate the gateway"

**Cause.** The agent authenticates the gateway before the bootstrap token leaves
the process, and it could not. Usually the gateway's certificate comes from a
private CA the agent's system trust store does not carry, or is self-signed.
Registration was abandoned before the token was sent, so nothing was leaked and
the token is still unused — but it is still ticking towards its 1-hour expiry.

**Fix.** Set `PROBE_AGENT_BOOTSTRAP_CA_BUNDLE` to that CA's PEM bundle, or
`PROBE_AGENT_BOOTSTRAP_PIN_SHA256` to the fingerprint of the certificate the
gateway presents. See [Authenticating the gateway at
enrolment](../install/agents.md#authenticating-the-gateway-at-enrolment).

### An agent refuses to enrol in production over `http://`

**Cause.** `DEPLOYMENT_ENV=production` and `PROBE_AGENT_SCHEDULER_URL` is not
`https://`, so the token would cross the wire in the clear. The agent raises
instead. `PROBE_AGENT_INSECURE_SKIP_BOOTSTRAP_TLS_VERIFY` is refused in
production too, so it is not a way round this.

**Fix.** Point the agent at an `https://` URL that terminates TLS in front of
the gateway. The `nginx.conf` and `apache.conf` shipped in `docker/deploy/`
already proxy the enrolment paths; a vhost you wrote yourself may not, and a
request that misses them is answered with the dashboard's `index.html` rather
than by the gateway. See [Reaching enrolment over
https](../install/agents.md#reaching-enrolment-over-https). On a private network
where the agent and the gateway share the Docker network, the alternative is to
leave `DEPLOYMENT_ENV` unset on the agent container, which is what the local
stacks do.

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

### Probes are skipped, and the banner says over capacity

Users see runs marked `skipped` and a `dispatch_capacity` banner. A skipped run
never reached an agent; three different faults produce one, and the banner says
which. The two entries after this one cover the others.

**Cause.** Either the dispatch queue overflowed (`SCHEDULER_DISPATCH_QUEUE_SIZE`,
default `100000` — it must exceed your largest per-tick fleet), or a service's
next tick came due while its previous tick was still waiting in the queue.
Both are capacity sheds; a run suppressed by the service's queue policy is
dropped silently and does not appear as `skipped`.

**Fix.** For overflow, raise the queue size — entries are tiny. For sustained
capacity pressure, **add agents**. Resist raising
`SCHEDULER_DISPATCH_WORKERS`: it is the global backpressure limit, and raising
it risks congestion collapse against slow targets. See [Scaling](scaling.md).

### Probes are skipped with no agent available

The alert is `no_eligible_agent`.

**Cause.** The tick found nothing to dispatch to. Either no agent is currently
passing its health challenge, or the affected services are restricted to agents
that are not — a service pinned to one agent has nowhere to go the moment that
agent stops being eligible.

**Fix.** Check agent health first (Settings → Agents, or
[Monitoring Tracedown](observability.md#agent-health)); a fleet that looks empty
to the scheduler is often one failing challenge away from working. If the fleet
is healthy, check the affected services' agent pickers — see
[Services](../guide/services.md#probe-agents).

### Probes are skipped although the agents look healthy

The alert is `agent_dispatch_failed`.

**Cause.** Agents were eligible — they passed a challenge within the last minute
— and every one of them was tried without a single one taking the run. The
connection was refused, the handshake did not complete, or the job was turned
away. This is what an agent lost *between* health rounds looks like: a container
killed, a network path closed, or a certificate the scheduler no longer trusts.

**Fix.** Confirm the agent processes are running and reachable inbound from the
scheduler on port 8443, and that their certificates are current. See [Probe
Agents](../install/agents.md) and
[Certificate Authority](certificate-authority.md).

### Runs are recorded with status `error`

**Cause.** The run did not evaluate. Either the script or the executor failed, or
the agent took the job and broke while running it — it answered HTTP 500, or
with something that is not a probe result. Such a run is never re-dispatched: the
agent may already have called the monitored target, and retrying would probe it
twice for one tick.

**Fix.** The diagnostic is stored with the run, on its **Raw result** tab. If it
points at the agent rather than the script, the agent's own logs have the rest.
See [Reading Results](../guide/results.md#errored-probes).

### Agent statuses are frozen and health checks report as unavailable

The alert is `health_token_unavailable`, and it names an endpoint rather than an
agent.

**Cause.** A health challenge requires the agent to fetch a one-time token from
the gateway. The scheduler could not reach that endpoint itself, or could not
store the token in Redis A to begin with — so the round proves nothing about the
agent and is discarded as inconclusive rather than held against it. Usually the
gateway is down, Redis A is unreachable, or `GATEWAY_URL` on the scheduler points
somewhere the scheduler cannot actually reach.

**Fix.** Check the gateway and Redis A, then `GATEWAY_URL` — its default
`http://localhost:8080` is not the gateway's own port and must be set
explicitly. See [Configuration](../install/configuration.md) and
[Monitoring Tracedown](observability.md#agent-health).

!!! note "The mirror-image fault reads as `agent_down`"
    `GATEWAY_URL` has to be reachable by the **agents** too — the scheduler
    hands each one `GATEWAY_URL` plus `/internal/health/token/{challengeId}` to
    fetch. A value only the scheduler can resolve, such as the internal Docker
    address against an agent on another host, produces the opposite symptom:
    the scheduler reaches the endpoint, so the round is not excused, and the
    agent is marked down instead. Agents off the Docker network need the public
    https URL there, which the shipped vhosts proxy — see [Reaching enrolment
    over https](../install/agents.md#reaching-enrolment-over-https).

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
