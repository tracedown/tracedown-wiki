---
description: "Run all of Tracedown from a single jar: one JVM, dashboard included, probes executed in-process. Needs only PostgreSQL, Redis and Java 17, plus the trade-offs."
---
# Monolith (single jar)

The monolith is the entire platform in one artifact: every service in a single
JVM, the dashboard served from the same port as the API, and probes executed by
an embedded Lace executor instead of external agents. It needs a PostgreSQL
database, a Redis instance, a Java 17 runtime — and nothing else. It applies
its own schema migrations on boot.

It exists because eight services is the right shape for a platform and the
wrong shape for a first install. If you are monitoring a handful of endpoints
for one team, the operational surface of the full stack — nine containers, a
migrator, an agent enrolment — buys you nothing you will use.

## The trade, stated plainly

The monolith trades the microservice properties for deployment simplicity, and
you should know what you are giving up:

- **No independent scaling.** You cannot add scheduler replicas or move
  ingestion to a bigger box; there is one process and it does everything.
- **No isolation.** One component's failure or memory pressure is everyone's.
  A JVM crash takes the API, the scheduler, and the WebSocket down together.
- **No rolling upgrades of a single piece.** Upgrading anything means
  restarting everything.
- **One vantage point.** Probes run inside the monolith's own process. There
  are no [probe agents](agents.md) to place in other regions or networks, and
  the Agents section of the UI is hidden accordingly — along with the
  per-service probe mode and agent selection, which only mean something when
  there is a fleet to select from.

None of this matters for a small installation, and the operational simplicity
wins. When it starts to matter, the exit is cheap: the
[per-service deployment](deploy.md) is the same code and the same schema —
point it at the same database and Redis and switch.

## Running it

Download `tracedown-monolith-<version>-all.jar` from the
[backend releases](https://github.com/tracedown/tracedown-core-backend/releases).
The published jar has the matching frontend release baked in, so the dashboard
is served from the gateway port with no separate frontend deployment.

```bash
DATABASE_URL=jdbc:postgresql://localhost:5432/tracedown \
DATABASE_USER=tracedown \
DATABASE_PASSWORD=change-me \
REDIS_A_URL=redis://localhost:6379 \
java -jar tracedown-monolith-<version>-all.jar
```

On an empty database it migrates the schema, initializes the internal
certificate authority, and (with the default `SINGLE_ORG_MODE=true`) bootstraps
the default organization and demo user — the same first-start behavior as the
full stack, including the demo credentials, so change them the same way (see
[Quickstart, step 2](quickstart.md#2-log-in)).

Open `http://localhost:20714` and log in. Services you create begin probing on
their schedule immediately — there is no agent to enrol.

!!! warning "Set real secrets before this reaches a network"
    Like the development Compose stack, the monolith boots with development
    defaults when secrets are unset — including the platform encryption key.
    Set `PLATFORM_AES_KEY` (64 hex chars, permanent — generate with
    `openssl rand -hex 32`), `JWT_SECRET`, and `DEPLOYMENT_ENV=production`,
    which makes startup refuse placeholder secrets instead of running with
    them. Work through [Secrets & Encryption](../admin/secrets.md).

### Environment

The monolith is configured entirely by environment variables — the same ones
the individual services read (the full reference is in
[Configuration](configuration.md)), because internally it *is* those services.
The variables specific to running them in one process:

| Variable | What | Default |
|---|---|---|
| `DATABASE_URL` | JDBC URL, `jdbc:postgresql://…` | required |
| `DATABASE_USER` / `DATABASE_PASSWORD` | Postgres credentials | required / `""` |
| `REDIS_A_URL` | Operational Redis | required |
| `REDIS_B_URL` | Cache Redis | falls back to `REDIS_A_URL` |
| `GATEWAY_PORT` | API + dashboard | `20714` |
| `REALTIME_PORT` | WebSocket | `20870` |
| `METRICS_PORT` | Prometheus scrape endpoint | `20850` |
| `WS_URL` | Overrides the WebSocket URL handed to the browser — set `/ws` behind a reverse proxy | direct to the realtime port |
| `STORAGE_FILESYSTEM_ROOT` | Saved response bodies | `/data/bodies` |

The shared `PORT` variable that platform-as-a-service hosts inject is
deliberately ignored: with every service in one process it cannot mean
anything.

The remaining services bind their usual ports (`20810`–`20870`) inside the
process. Nothing but the three in the table needs to be reachable — keep the
rest firewalled as you would any internal port.

### In a container

The jar runs fine in a stock JRE image; there is no dedicated monolith image.

```bash
docker run -d --name tracedown \
  -p 127.0.0.1:20714:20714 -p 127.0.0.1:20870:20870 \
  -v tracedown-bodies:/data/bodies \
  -e DATABASE_URL=jdbc:postgresql://your-postgres:5432/tracedown \
  -e DATABASE_USER=tracedown -e DATABASE_PASSWORD=… \
  -e REDIS_A_URL=redis://your-redis:6379 \
  -v ./tracedown-monolith-<version>-all.jar:/app.jar:ro \
  eclipse-temurin:17-jre java -jar /app.jar
```

### Behind a reverse proxy (TLS)

Put your web server in front exactly as with the
[per-service deployment](deploy.md): proxy `/` to the gateway port and `/ws`
(as a WebSocket upgrade) to the realtime port, then terminate TLS there.
One monolith-specific step: set `WS_URL=/ws` so the dashboard connects to the
WebSocket through your proxy on the page's own origin, rather than dialing the
realtime port directly — a direct `wss://host:20870` has no TLS to speak to.
The `nginx.conf` / `apache.conf` shipped in the backend's `docker/deploy/`
directory need only one adjustment: point the frontend locations at the
gateway port instead of a static bundle, since the monolith serves the
dashboard itself.

## The command-line tools

The gateway's CLI tools ride along in the jar, so the one artifact also
administers itself:

```bash
java -jar tracedown-monolith-<version>-all.jar --create-org "My Org" admin@example.com
```

`--agent-bootstrap` and `--agent-remove` are present too, for symmetry with the
gateway binary, but enrolled agents are never selected in the monolith — probes
always run in-process.

## What "in-process execution" means for results

Results are identical in shape to agent-executed probes — same timing
breakdown, same assertion detail, same body handling — with one visible
difference: the runs are not attributed to any agent, and probe history shows
them without an agent name. Timings are measured from wherever the monolith
runs, so latency numbers reflect that machine's network position — the
multi-region view that a fleet of agents gives you is precisely the thing this
edition trades away.
