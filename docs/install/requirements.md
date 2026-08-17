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

!!! note "About TimescaleDB"
    The Compose file pulls `timescale/timescaledb:latest-pg16`, but Tracedown
    creates no hypertables and requires no extensions — the image is a
    convenience, not a dependency. Any stock PostgreSQL 16 works. If you do use
    the TimescaleDB image, keep the `TS_TUNE_MAX_CONNS: "100"` setting: its
    tuner sizes `max_connections` from host memory at first boot, and on a small
    host it lands below what the service pools need, so the stack fails to come up.

## Source layout

Tracedown builds from a directory tree, not a single repository. The backend's
Docker build context is the **parent** directory, and its Dockerfile copies the
sibling `lace/` repositories into the build context:

```
tracedown/
  core/
    tracedown-core-backend/     # the JVM services + docker/ stack
    tracedown-core-frontend/    # the dashboard
    tracedown-probe-agent/      # the probe agent
  lace/
    lacelang-kotlin-validator/  # copied into the Docker build
    lacelang-kotlin-executor/   # copied into the Docker build
    kotlin-lacetest/            # copied into the Docker build
```

Cloning only `tracedown-core-backend` will fail the Docker image build at the
COPY step. Clone the siblings alongside it. (The Gradle build itself resolves
the Lace libraries from Maven Central, so building outside Docker does not need
them.)

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
