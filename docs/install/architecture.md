---
description: "How self-hosted Tracedown fits together: eight JVM services, a probe agent, PostgreSQL and Redis, joined by a transactional outbox, Redis queues and mTLS."
---
# Architecture

Tracedown is eight long-running JVM services, a one-shot schema migrator, a
Python probe agent, PostgreSQL, and Redis, fronted by a web server you run on
the host. This page
explains what each part does, how they communicate, and why the boundaries fall
where they do — which is mostly a story about never letting two services block
on each other.

## The shape of it

```
                     ┌──────────────┐
   browser ─────────▶│ host proxy   │  your nginx/apache (see deploy.md)
                     └──────┬───────┘
                            │ /api/ → gateway (127.0.0.1:20714)
                            │ /ws → realtime (127.0.0.1:20870)
                            │ /metrics/ → metrics (127.0.0.1:20850)
        ┌───────────────────┼────────────────────┬─────────────┐
        ▼                   ▼                    ▼             ▼
  ┌───────────┐      ┌────────────┐      ┌────────────┐  ┌──────────┐
  │  gateway  │      │  realtime  │      │  metrics   │  │  worker  │
  │   20714   │      │   20870    │      │   20850    │  │  20860   │
  └─────┬─────┘      └─────▲──────┘      └─────┬──────┘  └────┬─────┘
        │ nudge            │ pub/sub           │              │
        ▼                  │                   │              │
  ┌───────────┐            │                   │              │
  │ scheduler │────────────┼───────────────────┼──────────────┼──┐
  │   20810   │            │                   │              │  │
  └─────┬─────┘            │                   │              │  │
        │ mTLS POST /probe │                   │              │  │
        ▼                  │                   │              │  │
  ┌───────────┐            │                   │              │  │
  │   agent   │            │                   │              │  │
  │   8443    │──▶ your APIs                   │              │  │
  └─────┬─────┘            │                   │              │  │
        │ ProbeResult      │                   │              │  │
        ▼                  │                   │              │  │
  ╔═══════════════════════════════════════════════════════════╗  │
  ║                        Redis A                            ║◀─┘
  ║      queues · outbox nudges · sessions · pub/sub          ║
  ╚═════╦═════════════════════════════════════════════════════╝
        ║ BRPOP probe_results_queue
        ▼
  ┌───────────┐      ┌────────────┐      ┌────────────┐
  │ ingestor  │─────▶│ dispatcher │─────▶│   email    │
  │   20820   │outbox│   20830    │      │   20840    │
  └─────┬─────┘      └─────┬──────┘      └────────────┘
        │                  │ webhooks → your endpoints
        ▼                  ▼
  ╔═══════════════════════════════════════════════════════════╗
  ║                    PostgreSQL 16                          ║
  ╚═══════════════════════════════════════════════════════════╝
```

## The services

Each service is an independent Ktor process with its own port and its own
dependency set. Nothing here calls anything else here over HTTP.

| Service | Purpose | Port | Depends on |
|---|---|---|---|
| schema-migrator | Runs Flyway, then exits | — | Postgres |
| api-gateway | REST API, auth, resource CRUD, internal CA | 20714 | Postgres, Redis A, Redis B, Redis C (optional) |
| probe-scheduler | Cron → dispatch → agents; health challenges | 20810 | Postgres, Redis A, gateway |
| result-ingestor | Drains results into Postgres | 20820 | Postgres, Redis A |
| notification-dispatcher | Outbox → notifications and webhooks | 20830 | Postgres, Redis A |
| email-service | Sends queued email via a provider | 20840 | Redis A |
| metrics-service | Prometheus scrape, Grafana integration | 20850 | Postgres, Redis A, Redis B |
| aggregate-worker | Aggregation, retention, purge, cleanup | 20860 | Postgres, Redis A, Redis B, S3 (optional) |
| realtime-service | WebSocket fan-out | 20870 | Postgres, Redis A |
| probe agent | Executes Lace scripts | 8443 | scheduler (inbound) |

Every one of those ports answers `GET /ping` (liveness — static, touches
nothing) and `GET /health` (readiness — borrows and validates a database
connection, pings Redis). The queue consumers and the job runner included: they
were always Ktor servers, they simply had no routes. schema-migrator is the
exception, being a one-shot job with no server at all. Which dependencies a
service treats as required and which merely degrade it differs per service —
[Monitoring Tracedown](../admin/observability.md#health-endpoints) has the
table.

A few of these rows are worth unpacking.

**schema-migrator** exists as a separate service rather than as startup logic
inside each application because concurrent Flyway runs against one
`flyway_schema_history` table race. Making migration a process that runs to
completion and exits lets everything else gate on
`condition: service_completed_successfully` — no service can start against a
partially migrated schema. See [Database & Migrations](database.md).

**api-gateway** is the only service a user's browser talks to for data, and it
is also the internal certificate authority: it signs agent certificate signing
requests and issues the client certificate the scheduler presents to agents. It
carries CLI entry points as well — the same binary invoked as
`./bin/api-gateway --agent-bootstrap <slug>` mints an enrolment token. See
[Certificate Authority](../admin/certificate-authority.md).

**email-service** is the only application service with no database at all. It
consumes a queue from Redis A and hands each message to a provider. Keeping mail
delivery database-free means a provider outage or a slow SMTP handshake cannot
consume a connection from a pool that probe ingestion also needs.

**realtime-service** has the strictest configuration of the set:
`DATABASE_URL`, `DATABASE_USER`, `DATABASE_PASSWORD`, and `REDIS_A_URL` are
mandatory HOCON substitutions with no defaults, so the process refuses to start
without them rather than silently falling back to a localhost that isn't there.

**The stack ships no reverse proxy of its own.** The gateway, metrics, and
realtime services publish on 127.0.0.1, and a web server on the host routes by
path: `/api/` and `/ping` to the gateway, `/metrics/` to metrics-service, and
`/ws` to realtime-service with the WebSocket upgrade and a 24-hour read
timeout. Three named paths under `/internal/` also go to the gateway — agent
registration, certificate renewal and the health-challenge token endpoint —
which is what lets an agent on another host enrol and stay healthy over https.
Ready-made `nginx.conf` and `apache.conf` files ship with the [Production
Deploy](deploy.md) stack; TLS termination happens there too.

`tracedown-core-common` is a shared library — models, config, Redis and storage
helpers — not a deployable service. It never appears in a process list.

## Redis has three roles, not three instances

Tracedown addresses Redis as three logical roles. The Compose stack points all
three at one instance, and that is the correct default.

| Role | Contents | Durability |
|---|---|---|
| **A** | Outbox nudges, sessions, work queues, pub/sub | AOF-persisted. Losing it loses queued work. |
| **B** | Metrics cache, rate limits | Ephemeral. Safe to lose; it refills. |
| **C** | Resource-hierarchy cache | Optional. Disabled when `REDIS_C_URL` is empty. |

The split exists at the URL layer so it can be exercised later without a code
change: repoint `REDIS_B_URL` and `REDIS_C_URL` at new hosts and the roles
separate. The Compose file carries commented-out service blocks for exactly
this, and states the thresholds that justify it — sustained throughput above
roughly 1,000 probe results per minute, a need for failure isolation so that
cache eviction can never risk dropping queued results or outbox events, or a
need to tune persistence and eviction independently (A wants AOF, B and C want
`allkeys-lru` and no persistence at all). Below those thresholds, one instance
is fine and two more are just more to operate. [Scaling](../admin/scaling.md)
covers the move.

## How work flows

The whole pipeline is one direction, and every hop between services is a queue
or a table.

1. **Quartz fires.** The scheduler holds cron triggers in memory and ticks per
   service.
2. **The scheduler resolves and selects.** It resolves the script's scoped
   variable references (`$o.` organization through `$s.` service) and selects
   agents according to the service's strategy.
3. **The job is enqueued.** The Quartz job pushes a service ID onto a bounded
   in-process dispatch queue and returns immediately. Trigger timing is thereby
   decoupled from agent latency: a hundred crons firing on the same second
   enqueue in microseconds instead of starving the Quartz thread pool.
4. **A dispatch worker POSTs `/probe`** to the chosen agent over mutual TLS,
   carrying the script, resolved variables, and any stored values from the
   previous run. A dispatch that fails before the probe can start moves to the
   next eligible agent; one that fails after the agent has taken the job does
   not, because the target may already have been called.
5. **The agent executes the Lace script** against your API and returns raw
   ProbeResult JSON. The agent is stateless — it holds no schedule, no history,
   and no database.
6. **The scheduler pushes the result** onto the Redis A `probe_results_queue`.
   Its job ends there; it never writes probe results itself.
7. **result-ingestor BRPOPs the result** and, in a single transaction, persists
   `probe_results` and `probe_steps`, updates `services.last_status`, and writes
   `outbox` rows. A run that never reached an agent is persisted as `skipped`
   instead: it is history only, changing no status and writing no outbox row.
8. **notification-dispatcher consumes the outbox**, evaluates silences and
   quiet hours, and delivers email (via the Redis A email queue) and webhooks.
   (Maintenance windows never reach this stage — the scheduler suppresses
   in-window services before dispatch.)
9. **realtime-service broadcasts** to connected dashboards over WebSocket from
   Redis A pub/sub.
10. **aggregate-worker rolls up** hourly and daily buckets, enforces retention,
    purges soft-deleted rows, and cleans up sessions and agent health history.

### Why the outbox

Step 7 is the load-bearing one. The ingestor writes outbox rows in the *same
transaction* as the results themselves, so it is impossible to have a stored
probe result whose notification was never queued, or a notification for a result
that got rolled back. The alternative — the ingestor calling the dispatcher over
HTTP — would make every result write depend on the dispatcher being up, and
would need its own retry and deduplication logic to boot.

This generalizes: **there is no synchronous HTTP between backend services.** A
service that is down is a queue that is draining slowly, not an outage. The one
deliberate exception is the scheduler's outbound call to an agent, which cannot
be a queue because it is a request/response probe with a deadline.

### The nudge, and its backstop

Polling a database for schedule changes trades latency against load, and picking
a poll interval means picking which one to lose. Tracedown does both instead.

When a service is created, updated, deleted, or toggled, the gateway publishes
`schedule:nudge {serviceId}` on Redis A pub/sub. The scheduler subscribes and
picks the change up immediately. Pub/sub is fire-and-forget — a scheduler that
was restarting when the nudge fired never sees it — so a periodic consistency
sweep reconciles Quartz against the database as the backstop
(`SCHEDULER_SWEEP_INTERVAL`, default 300 seconds; the Compose stack sets 10 for
fast feedback in development). The nudge provides the latency; the sweep
provides the correctness guarantee.

### Running more than one scheduler

Quartz uses a RAM job store, so every scheduler replica builds its own trigger
set and every replica ticks for every service. What makes that safe is a Redis
lock: the scheduler's `QueuePolicyManager` takes a per-service lock before
dispatching, and only the holder dispatches for that tick. The others find the
lock held and drop their tick.

The consequence is worth stating plainly: **scheduler replicas must share the
same Redis A.** Point two schedulers at two different Redis instances and each
will happily win its own lock, and every probe runs twice.

## mTLS, and which way the connection goes

Everything agent-facing is mutually authenticated. The gateway operates an
internal CA; agents generate an RSA-4096 keypair, submit a CSR using a one-time
bootstrap token, and hold a CA-signed certificate afterwards. The scheduler
generates an ephemeral client certificate from the same CA at startup, so both
ends of a dispatch present certificates and neither trusts anything else.

The one request that predates all of it is the CSR itself, which carries the
token and receives the CA bundle the agent then pins. The agent authenticates
the gateway on that request too — against the system trust store, or a CA bundle
or certificate fingerprint you give it out of band — and refuses to send the
token if it cannot. See [Authenticating the gateway at
enrolment](agents.md#authenticating-the-gateway-at-enrolment).

The direction matters for your network design: **the scheduler dials the
agent.** Agents do not poll for work. An agent must therefore be reachable
inbound from the scheduler on port 8443 — an agent behind NAT with no inbound
route will register successfully, look healthy in the UI, and never receive a
single probe. This is the deliberate trade: it is what lets the scheduler
enforce dispatch concurrency globally, which an agent-pull model cannot do.

Agent health follows the same philosophy as everything else here — it is
established by running an actual Lace script that fetches a token from the
gateway, not by pinging a liveness endpoint. An agent that responds to TCP but
cannot execute a script is not healthy in any sense that matters. See [Probe
Agents](agents.md).

## Backpressure

The dispatch queue is bounded at `SCHEDULER_DISPATCH_QUEUE_SIZE`, default
100,000. Entries are just service IDs at roughly 50 bytes each, so the default
is generously above any realistic per-tick fleet. When it does fill, the
overflow is shed and those runs are recorded as `skipped` — surfaced in the UI
as the probe being over capacity. Shedding is the intended behaviour: a probe
result that arrives long after its scheduled minute is not a monitoring signal,
it is noise, and an unbounded queue would convert a load spike into an
out-of-memory kill.

`SCHEDULER_DISPATCH_WORKERS`, default 50, caps concurrent in-flight dispatches.
Because each worker awaits the agent's full probe round-trip, this doubles as
global backpressure on the outside world: it is the ceiling on how many
connections the platform opens against your targets at once.

!!! warning "Resist raising `SCHEDULER_DISPATCH_WORKERS`"
    Fifty is deliberate, not a placeholder. Raising it lets the scheduler
    overwhelm a slow target — observed in testing as congestion collapse and
    runaway latency against a single endpoint over the internet, where the
    monitoring became the outage. If probes are queueing, add agents. Raise this
    only when you know the targets can absorb the extra concurrency.

## Where the data lives

PostgreSQL is the system of record: organizations, workspaces, projects,
services, probe scripts, variables, results, steps, aggregates, the outbox, and
the CA. No extensions are required and no hypertables are created, so any stock
PostgreSQL 16 will do. Redis A holds in-flight work and sessions. Response
bodies, when saving is enabled, go to a filesystem volume or an S3-compatible
store; body saving is off by default, since storing every response body of every
probe is expensive and rarely what you want. The aggregate-worker is the service
that deletes them when retention expires, which is why it is the only one with
optional S3 credentials.

## Next

[Configuration](configuration.md) is the full environment-variable reference.
[Scaling](../admin/scaling.md) covers replica counts, splitting Redis, and the
resource overlay. [Probe Agents](agents.md) covers deploying agents beyond the
one the quickstart enrols.
