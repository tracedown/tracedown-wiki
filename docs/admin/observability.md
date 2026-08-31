---
description: "Monitoring Tracedown itself: the Prometheus scrape endpoint for probe results, Grafana integration tokens, health endpoints, agent health challenges and logs."
---
# Monitoring Tracedown

Tracedown watches your APIs. This page is about watching Tracedown — knowing
that the platform itself is healthy, that its agents are executing probes, and
that it is not silently shedding work.

Be clear on one distinction before you start, because the naming invites a
wrong assumption: the Prometheus endpoint described below publishes **your probe
results**. It is a way to get monitoring data *out* of Tracedown into Grafana.
It is not JVM or internal telemetry about Tracedown's own health. Tracedown does
not export its own runtime metrics. The tools for watching the platform itself
are the health endpoints, the system alerts, the agent health challenges, and
the logs.

## The Prometheus scrape endpoint

metrics-service exposes probe results in Prometheus format at `/metrics/{id}`
on port 20850, which nginx proxies at `/metrics/`. The `{id}` is a Grafana
integration id, and integrations are configured **per project** — not globally.

In the dashboard, open the project's **Settings** tab and find the **Grafana
integration** card. Enabling an integration shows a bearer token **once**, and
makes the scrape endpoint copyable. Point a Prometheus data source at that URL
and authenticate with:

```
Authorization: Bearer <token>
```

An integration can be paused, have its token regenerated, or be deleted. It can
also be scoped to a subset of the project's services — leaving the scope empty
means all services.

The public base URL shown in those integration instructions comes from
`METRICS_PUBLIC_URL` on the gateway. If your users are copying a URL that points
at an internal hostname, that is the setting to fix. For what the exported data
means, see [Reading Results](../guide/results.md).

### Metric cache lifetimes

metrics-service caches computed metrics in Redis B. Two settings control how
long:

| Variable | Default | Meaning |
|---|---|---|
| `METRICS_TTL_SECONDS` | `86400` | Cached metric lifetime |
| `METRICS_HOURLY_BUCKET_TTL_SECONDS` | `90000` | Hourly bucket lifetime |

## Health endpoints

Every long-running service answers two endpoints on its own port, and they
answer different questions. Confusing them is how a Redis blip turns into a
restart loop.

| Endpoint | Question | Touches |
|---|---|---|
| `GET /ping` | **Liveness.** Is the process up and serving? | Nothing. It is static on purpose — a probe wired to it never restarts a service over a dependency outage that restarting cannot fix. |
| `GET /health` | **Readiness.** Can it actually do its job? | Borrows a connection from the database pool and validates it, `PING`s each Redis it needs. |

```bash
wget -q -O- http://localhost:20714/ping     # {"status":"ok"}
wget -q -O- http://localhost:20714/health   # the full readiness report
```

`/health` returns a JSON object naming every check:

```json
{
  "status": "ok",
  "service": "api-gateway",
  "checks": {
    "database": { "status": "ok", "required": true },
    "redis-a":  { "status": "ok", "required": false }
  }
}
```

`status` is `ok` when everything passes, `degraded` when only a non-required
check fails, and `unhealthy` when a required one does. The HTTP status follows
the same split: **503** for `unhealthy`, **200** for both `ok` and `degraded`.
That is the point of the required flag — a dependency the service is designed to
survive without is reported, not fatal.

Neither endpoint authenticates; a readiness probe cannot hold credentials. So
the body names *which* dependency failed and nothing more. The reason — a driver
exception, which can carry a JDBC URL or a hostname — goes to the service's log
instead, one WARN line per failed check.

### What each service checks

| Service | Port | `/ping` | Required | Reported, not required |
|---|---|---|---|---|
| api-gateway | 20714 | yes | `database` | `redis-a` |
| probe-scheduler | 20810 | yes | `database`, `redis-a` | — |
| result-ingestor | 20820 | yes | `database`, `redis-a` | — |
| notification-dispatcher | 20830 | yes | `database`, `redis-a` | — |
| email-service | 20840 | yes | `redis-a` | — |
| metrics-service | 20850 | yes | `database`, `redis-b` | `redis-a` |
| aggregate-worker | 20860 | yes | `database` | `redis-b` |
| realtime-service | 20870 | yes | `database`, `redis-a` | — |
| schema-migrator | — | no | — | — |

The asymmetries are deliberate, and each says something about the service:

- **api-gateway** treats Redis A as optional because rate limiting and email
  queueing both degrade rather than stop. The database it cannot answer
  anything without.
- **email-service** holds no database at all — it is a pure queue consumer, so
  Redis A is the whole of its readiness.
- **metrics-service** requires Redis B, where it caches computed metrics, and
  only reports Redis A, which carries the nudge subscription.
- **aggregate-worker** requires the database it aggregates and purges, and only
  reports Redis B, a cache it can run without.
- **realtime-service** requires both: sessions are validated against Postgres on
  every connect, and with Redis A gone a socket connects and then receives
  nothing — which is worse than reporting not-ready.
- **schema-migrator** is a one-shot job. It runs Flyway to completion and exits;
  there is no server to ask. Its health is its exit code.

!!! note "Two `/ping` responses differ in shape"
    api-gateway and realtime-service had a `/ping` before the shared endpoints
    existed and kept their own, because callers depend on the body:
    api-gateway answers `{"status":"ok"}`, realtime-service answers the plain
    text `pong`. Everywhere else `/ping` is `{"status":"ok"}`. All eight
    `/health` responses share the shape above.

### Wiring them up

Use `/ping` for container liveness and `/health` for readiness — which is what
the shipped `docker/deploy/docker-compose.yml` does, giving every service a
`wget` healthcheck against its `/ping`. The gateway's gates the scheduler's
start; the rest are there so `docker compose ps` tells the truth.

`/health` is **not** published by the shipped `nginx.conf` / `apache.conf`.
They proxy the gateway's `/ping` and nothing else health-related, so readiness
stays on the internal network where an unauthenticated dependency report
belongs. Reach it from inside:

```bash
docker compose exec tracedown-metrics wget -qO- http://localhost:20850/health
```

## In-product warnings

The platform raises its own system alerts when it detects operational trouble.
These are the highest-signal thing an operator can watch, because they are
raised from inside the code paths that know something went wrong.

| Type | Meaning |
|---|---|
| `dispatch_capacity` | A probe run was shed — the platform is over dispatch capacity |
| `no_eligible_agent` | A probe run found no agent it was allowed to run on |
| `agent_dispatch_failed` | Every eligible agent was tried and none of them took the run |
| `agent_down` | An agent failed its health challenge twice in a row |
| `agent_degraded` | An agent responded, but too slowly |
| `health_token_unavailable` | The health-challenge token endpoint is unreachable from the scheduler |

Alerts appear as banners in the dashboard. The full history lives in
**Settings → Warning log**, which records severity, type, subject, first seen
and last seen — so an alert that fired once at 3am is still there in the
morning. Watch this. See the [User Manual](../guide/index.md).

The first three are raised by result-ingestor when it persists a run with status
`skipped`, and which one it raises depends on why the run was skipped.
`dispatch_capacity` means the dispatch queue overflowed, or a service's next tick
came due while its previous tick was still waiting in it — both are capacity
sheds. `no_eligible_agent` means the tick found nothing healthy, or nothing the
service was restricted to, to run on. `agent_dispatch_failed` means agents were
eligible and every one of them was tried without a single one taking the job,
which is what an agent lost between health rounds looks like. (Queue-policy
collisions do not produce skipped runs; they are dropped silently.) See
[Scaling](scaling.md).

## Agent health

The scheduler challenges every active agent once a minute, on the Quartz cron
`30 * * * * ?` — that is, at **:30 past each minute**. The offset is
deliberate. Probes overwhelmingly schedule on the minute boundary, so a
challenge at :00 would compete with the fleet-wide dispatch burst and read
normal load as degradation.

The challenge is not a ping. The scheduler generates a one-time token, stores it
in Redis A with a 30-second TTL, and asks the agent to fetch it from the
gateway. The agent does this by **running a real Lace script**. Returning the
correct token therefore proves the executor works, the agent can reach the
gateway, and the network path is intact — not merely that a process is
listening.

Each challenge is recorded with its result and round-trip time:

| Result | Meaning |
|---|---|
| `pass` | Correct token returned |
| `fail` | Agent reported failure, or the request errored |
| `timeout` | No response within the challenge timeout |
| `wrong_token` | Responded, but the token did not match |
| `inconclusive` | The round observed nothing about the agent — see below |

An agent is marked failed only after **two consecutive** non-passing rounds, and
recovers on the first pass. Fail slow, recover fast: one blip does not empty the
fleet, and a real outage is still caught inside two minutes. `agent_down` is
raised on the second round rather than the first, so the banner and the agent's
recorded status never disagree. A passing challenge whose round-trip exceeds
**1200 ms** raises `agent_degraded` — the agent works, but slowly enough that
probe timings from it are suspect.

Passing the challenge requires the agent to reach the gateway, so a failed round
can just as easily be the platform's fault as the agent's. When an agent answers
that it could not complete the challenge, the scheduler checks the token
endpoint itself before holding it against the agent. If it cannot reach the
endpoint either — or could not store the token there in the first place — the
round is recorded as `inconclusive` and raises `health_token_unavailable`,
naming the endpoint rather than an agent. An inconclusive round leaves the
agent's status alone, does not count towards the two, and leaves it eligible for
dispatch. Without it, one unreachable endpoint would convict the whole fleet in
a single round and dispatch would then find nothing left to run on.

History is retained per `AGENT_HEALTH_RETENTION_DAYS` (default `90`), so you can
correlate a bad week of probe latency against agent health rather than assuming
the target regressed. See [Probe Agents](../install/agents.md).

## Logs

Every service logs to stdout, so the standard Docker tooling applies:

```bash
docker compose logs -f tracedown-scheduler
docker compose logs -f tracedown-ingestor
```

!!! note "There is no bundled log aggregation"
    Tracedown ships no log shipper, no aggregation stack, and no log search UI.
    If you want centralised logs, point your own collector at the container
    stdout streams. The system alerts and the warning log are the intended
    first stop for operational trouble; the logs are where you go for detail
    once an alert tells you where to look.
