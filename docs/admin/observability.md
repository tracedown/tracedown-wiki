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
are the health endpoint, the system alerts, the agent health challenges, and the
logs.

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

The api-gateway answers `GET /ping`. The bundled compose uses it as the
gateway's healthcheck, which gates the scheduler's and nginx's startup:

```bash
wget -q -O- http://localhost:20714/ping
```

nginx routes `/ping` to the gateway, so it is reachable through the front door
as well. realtime-service also exposes a `/ping` route on port 20870. The other
services do not expose health endpoints — for those, container liveness and the
logs are what you have.

## In-product warnings

The platform raises its own system alerts when it detects operational trouble.
These are the highest-signal thing an operator can watch, because they are
raised from inside the code paths that know something went wrong.

| Type | Meaning |
|---|---|
| `dispatch_capacity` | A probe run was shed — the platform is over dispatch capacity |
| `agent_down` | An agent failed its health challenge |
| `agent_degraded` | An agent responded, but too slowly |

Alerts appear as banners in the dashboard. The full history lives in
**Settings → Warning log**, which records severity, type, subject, first seen
and last seen — so an alert that fired once at 3am is still there in the
morning. Watch this. See the [User Manual](../guide/index.md).

`dispatch_capacity` is raised by result-ingestor whenever it persists a run with
status `skipped`. That means the dispatch queue overflowed, or a service's next
tick came due while its previous tick was still waiting in the queue — both are
capacity sheds. (Queue-policy collisions do not produce skipped runs; they are
dropped silently.) See [Scaling](scaling.md).

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

Anything other than `pass` raises `agent_down`. A passing challenge whose
round-trip exceeds **500 ms** raises `agent_degraded` — the agent works, but
slowly enough that probe timings from it are suspect.

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
