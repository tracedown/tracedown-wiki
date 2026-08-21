---
description: "Which Tracedown services are safe to replicate and which must run exactly once, plus scheduler throughput, agent capacity, database pools and splitting Redis."
---
# Scaling

Tracedown scales along three mostly independent axes: how many probes the
scheduler can have in flight, how many probes the agent fleet can execute, and
how many database connections the JVM services collectively demand. They fail in
different ways and have different levers. This page covers each in turn, plus
the resource overlay and the Redis split.

The single most important thing on this page is the replica table below. Get it
wrong and you get duplicated work rather than an error message.

## Replica safety

Not every service is safe to run more than once. The distinction is whether the
service coordinates through Redis or simply assumes it is alone.

| Service | Replicas | Why |
|---|---|---|
| probe-scheduler | Multiple — safe | Quartz uses a RAM job store, so every replica schedules independently. Cross-replica safety comes from a Redis-backed lock taken per service before dispatch. |
| aggregate-worker | **Exactly one** | No distributed lock. Jobs are plain coroutine loops. |
| api-gateway | Multiple — safe | Stateless HTTP server. |
| result-ingestor | Multiple — safe | Consumes the result queue with an atomic blocking pop; each result is taken by exactly one replica. |
| notification-dispatcher | **Exactly one** | Polls the outbox without row locking; replicas race the same unpublished rows and double-deliver emails and webhooks. |
| email-service | Multiple — safe | Consumes the email queue with an atomic blocking pop. |
| metrics-service | **Exactly one** | The scrape side is stateless, but the nudge listener increments Redis counters, and pub/sub delivers each nudge to every replica — N replicas multiply every counter by N. |
| realtime-service | Multiple — safe | Each replica fans pub/sub events out to its own connected sockets. |

### Why the scheduler is safe

Each replica runs its own Quartz scheduler and will independently decide that a
service is due at the same cron tick. The safety net is `QueuePolicyManager`,
which does a Redis `SET NX` on `probe_active:{serviceId}` before dispatching.
Exactly one replica acquires the key; the others lose. A losing replica does not
error — it applies the service's queue policy, so the run is either **skipped**
or **enqueued**.

This works only because all replicas coordinate through the same Redis A
instance. Point two schedulers at different Redis instances and both will
dispatch every run.

!!! warning "All scheduler replicas must share Redis A"
    The lock is the only thing preventing duplicate dispatch. `REDIS_A_URL` must
    resolve to the same instance for every replica.

### Why the worker is not

The aggregate-worker's hourly aggregation, daily aggregation, retention, purge
and session cleanup jobs are plain coroutine loops on an interval. There is no
lock and no leader election. A second replica does not corrupt anything, but it
duplicates every aggregation and retention pass — wasted database load, and
retention deleting rows another replica is mid-aggregation over. Run exactly
one. See [Retention & Aggregation](retention.md).

### Why the dispatcher and metrics-service are not

The notification-dispatcher polls the outbox for unpublished rows, delivers,
and only then marks them published. There is no row locking and no consumer
cursor coordination between processes, and the Redis nudge that wakes the
poller is pub/sub — broadcast to every subscriber. Two replicas therefore race
the same unpublished rows and both deliver: duplicate emails, duplicate webhook
calls. Run one.

metrics-service has the same shape on its write path. Serving scrapes is
stateless, but its nudge listener increments counters in Redis for every probe
result it hears about, and every replica hears about every result. Two
replicas double every counter the scrape endpoint later reports. Run one.

## Scheduler throughput

Three settings govern the scheduler's capacity. Only one of them is a throughput
lever, and it is not the one people reach for.

| Variable | Default | Meaning |
|---|---|---|
| `SCHEDULER_DISPATCH_WORKERS` | `50` | Concurrent in-flight dispatches |
| `SCHEDULER_DISPATCH_QUEUE_SIZE` | `100000` | Queued service ids awaiting a worker |
| `SCHEDULER_THREAD_POOL_SIZE` | `10` | Quartz threads |

### Dispatch workers are backpressure, not throughput

Each dispatch worker awaits the agent's full probe round-trip before taking the
next item. That makes `SCHEDULER_DISPATCH_WORKERS` the platform's global
backpressure limit: it caps how many connections Tracedown opens against your
targets at once, across every service and every agent.

It is 50 deliberately. Raising it lets the scheduler overwhelm a slow target —
the observed failure is congestion collapse and runaway latency against a single
endpoint over the public internet. Every probe then reports degraded latency
that your API is not actually exhibiting, so you have converted a capacity
problem into a monitoring accuracy problem.

!!! tip "Add agents, do not raise the worker count"
    If you need more probe throughput, add agents. Agents parallelise execution
    without increasing the concurrency any single target sees from a single
    scheduler. Raise `SCHEDULER_DISPATCH_WORKERS` only when you know the targets
    absorb the extra concurrency — for example, an internal fleet on a LAN.

### Queue size

The queue holds service ids — roughly 50 bytes each — so the default of 100000
costs almost nothing. It must exceed your largest per-tick fleet: the number of
services that can come due on the same cron tick. On overflow the excess is
shed, and those runs are recorded as `skipped`. Your users see the probe
reported as over capacity, and the platform raises a `dispatch_capacity` system
alert — see [Monitoring Tracedown](observability.md).

## Agent throughput

`PROBE_AGENT_MAX_CONCURRENCY` (default `256`) sizes the agent's dedicated probe
execution pool. This exists because Python's default asyncio executor pool is
only `min(32, cpu_count + 4)` threads. When probing over the public internet,
where each probe spends most of its wall time blocked on the network rather than
on CPU, that default caps throughput far below what the host can handle.

Size it from your own numbers:

```
max_concurrency ≈ peak_probes_per_second × avg_probe_seconds
```

A fleet doing 20 probes/second against targets averaging 2 seconds needs ~40
concurrent slots. The 256 default has substantial headroom; raise it only when
you have measured a queue building at the agent. See
[Probe Agents](../install/agents.md).

## Database connections

This is the constraint that actually bites first on a small host.

HikariCP fills its pool to maximum eagerly rather than lazily. Eight JVM
services at the default pool size of 10 therefore hold **80 connections** —
idle, permanently — against a Postgres configured for 100. There is very little
left for anything else, and a ninth consumer (a `psql` session, a backup job)
can tip it over.

`DB_POOL_SIZE` tunes the pool per service. But it does not apply everywhere:

!!! warning "Three services ignore `DB_POOL_SIZE`"
    aggregate-worker, metrics-service and realtime-service pass
    `maximumPoolSize = 5` explicitly in code, which overrides the environment
    variable. The resource overlay sets `DB_POOL_SIZE` for them anyway, which
    is misleading — those values have no effect. Their pools are 5 regardless.
    Budget accordingly.

### TimescaleDB and max_connections

If you use the TimescaleDB image, `TS_TUNE_MAX_CONNS` matters more than it
looks. `timescaledb-tune` runs at initdb and derives `max_connections` from
available host memory. On a small host it lands *below* what the service pools
need, and the stack cannot boot at all — services fail to acquire connections
and exit. The bundled compose sets `TS_TUNE_MAX_CONNS: "100"` for exactly this
reason.

Because it is applied at initdb, changing it later has no effect on an existing
data volume. See [Database & Migrations](../install/database.md).

## The resource-limits overlay

The repository ships an overlay that approximates a small production VM
(~8 vCPU / ~7 GB for the whole stack), so load tests surface OOM kills, CPU
throttling and GC pressure instead of quietly borrowing the whole dev machine.

```bash
docker compose -f docker-compose.yml -f docker-compose.limits.yml up -d
```

It sets three things: per-service CPU and memory caps,
`JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=60` so each JVM sizes its heap from the
container cap rather than the default 25%, and per-service `DB_POOL_SIZE` (with
the caveat above).

??? note "Per-service limits in the overlay"
    | Service | CPUs | Memory | `DB_POOL_SIZE` |
    |---|---|---|---|
    | tracedown-postgres | 2 | 2g | — |
    | tracedown-redis-a | 0.5 | 512m | — |
    | tracedown-gateway | 1 | 768m | 6 |
    | tracedown-scheduler | 1 | 768m | 6 |
    | tracedown-ingestor | 1 | 512m | 4 |
    | tracedown-dispatcher | 0.5 | 512m | 3 |
    | tracedown-email | 0.25 | 384m | 2 |
    | tracedown-metrics | 0.5 | 512m | 3 (ignored) |
    | tracedown-worker | 0.5 | 512m | 3 (ignored) |
    | tracedown-realtime | 0.5 | 384m | 2 (ignored) |
    | tracedown-nginx | 0.5 | 128m | — |

The probe agent is not compose-managed, so the overlay cannot limit it. Cap it
on the running container:

```bash
docker update --cpus 2 --memory 3g --memory-swap 3g tracedown-agent-dev-agent
```

## Splitting Redis

Tracedown addresses Redis in three roles — A (operational queues, outbox
nudges, pub/sub; AOF-persisted), B (cache), and C (optional hierarchy cache).
By default `REDIS_A_URL`, `REDIS_B_URL` and `REDIS_C_URL` all point at a single
instance, and for most deployments that is enough.

The separation lives at the URL layer, not the data layer, so splitting them out
is purely a configuration change: stand up the instances and repoint the URLs.
The compose file carries commented-out service blocks for B and C ready to
uncomment.

Split when you hit one of these:

- Sustained throughput above roughly **1k probe results per minute**.
- You need **failure isolation** — cache eviction should never risk dropping
  queued results or outbox events.
- You want to tune **persistence and eviction independently**. A wants AOF; B
  and C want `--save ""` with an `allkeys-lru` maxmemory policy, since
  everything in them is reconstructible.

That last point is the real argument. Sharing one instance forces one
persistence policy onto data with opposite durability requirements: either you
pay AOF cost for a cache, or you risk losing queued results to an eviction.
