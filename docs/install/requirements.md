---
description: "Host sizing, Docker, PostgreSQL 16 and Redis 7 versions needed to run self-hosted Tracedown - and why any stock PostgreSQL 16 will do."
---
# Requirements

## Host

| Resource | Minimum | Comfortable |
|---|---|---|
| CPU | 4 vCPU | 8 vCPU |
| Memory | 4 GB | 8 GB |
| Disk | 20 GB | 50 GB+ — grows with retention and saved bodies |

Nine JVM services, Postgres, and Redis run side by side. On a small host,
apply the resource overlay described in [Scaling](../admin/scaling.md) — it caps
each JVM's heap and connection pool so the stack fits in roughly 8 vCPU / 7 GB.

## Software

| Component | Version | Notes |
|---|---|---|
| Docker Engine | 24+ | With the Compose plugin (`docker compose`, not `docker-compose`). |
| PostgreSQL | 16 | Supplied by the stack. **No extensions required.** |
| Redis | 7 | Supplied by the stack. |
| JDK | 17 | Only to build outside Docker. The images bundle their own. |
| Python | 3.10+ | Only to run the probe agent outside Docker. |
| Node.js | 18+ | Only to build or run the dashboard outside Docker. |

!!! note "Any stock PostgreSQL 16 works"
    The Compose file pulls `postgres:16-alpine`. Tracedown creates no
    hypertables, installs no extensions and depends on no particular
    distribution — a container, a distro package or a managed instance are all
    fine. See [Database & Migrations](database.md).

!!! warning "`max_connections` must be at least 160"
    The stack reserves **103** connections while idle, so the PostgreSQL default
    of 100 is not enough and the stack will not finish booting on it. The
    bundled Compose file raises it with `postgres -c max_connections=160`; if
    you point Tracedown at your own PostgreSQL, raise it there instead. The
    arithmetic is in [Scaling](../admin/scaling.md#database-connections).

## Source layout

Only relevant when building the images from source — the
[production deploy](deploy.md) runs from published release artifacts and needs
none of this.

All Lace libraries are pinned Maven Central dependencies (`dev.lacelang:*`),
so there are no extra repositories to clone or copy. The one convention that
remains: the backend's Docker build context is the **parent** of the
repository root, so clone into a fixed tree:

```
tracedown/
  core/
    tracedown-core-backend/     # the JVM services + docker/ stack
    tracedown-core-frontend/    # the dashboard
    tracedown-probe-agent/      # the probe agent
```

## Network

| Port | Who | Purpose |
|---|---|---|
| `20714` | api-gateway | REST API and health. Published on 127.0.0.1; your web server proxies to it. |
| `20870` | realtime-service | WebSocket. Published on 127.0.0.1; proxied by your web server. |
| `20850` | metrics-service | Prometheus scrape endpoint. Published on 127.0.0.1. |
| `5555` | Postgres | Mapped to the host by the dev stack. **Do not expose publicly.** |
| `8443` | Probe agent | The scheduler connects here over mutual TLS. |

Agents must be reachable *from* the scheduler — the scheduler dials the agent,
not the other way round. An agent behind NAT with no inbound route will register
and then never receive work.

Outbound, agents need to reach whatever you are monitoring, and the host needs
to reach your email provider if you configure one.
