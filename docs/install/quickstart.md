---
description: "Run self-hosted API monitoring locally with Docker Compose: bring up Postgres, Redis and nine JVM services, log in, and enrol your first probe agent."
---
# Quickstart (Docker)

This page takes you from an empty directory to a running Tracedown with one
probe agent enrolled. It uses the development Compose stack shipped in
`core/tracedown-core-backend/docker/`, which brings up Postgres, Redis, and all
nine JVM services in a single command. (For production, use the
[release-artifact deploy](deploy.md) or the [monolith](monolith.md) instead —
this stack builds everything from source.)

Budget a few minutes of wall clock — most of it is the first Gradle build.

!!! warning "This stack ships with development secrets"
    The bundled `docker/.env.example` contains a placeholder encryption key, a
    placeholder JWT secret, and a published demo password. That is fine on your
    laptop and unacceptable anywhere another person can reach. Before you put
    this on a network, work through [Secrets & Encryption](../admin/secrets.md).

## Before you start

Check [Requirements](requirements.md) for host sizing and Docker versions. The
one thing worth repeating here, because it is the most common first failure:

## Clone into the expected tree

The backend's Docker build context is the **parent** of the repository root
(`context: ../../..` in the Compose file), so the repositories go into a fixed
layout. All Lace libraries are pinned Maven Central dependencies — nothing else
to clone.

Concretely:

```bash
mkdir tracedown && cd tracedown
git clone https://github.com/tracedown/tracedown-core-backend  core/tracedown-core-backend
git clone https://github.com/tracedown/tracedown-core-frontend core/tracedown-core-frontend
git clone https://github.com/tracedown/tracedown-probe-agent   core/tracedown-probe-agent
```

```
tracedown/
  core/
    tracedown-core-backend/     # the services and the docker/ stack
    tracedown-core-frontend/    # the dashboard
    tracedown-probe-agent/      # the probe agent
```

## 1. Bring up the backend

From `core/tracedown-core-backend/docker/`, create your `.env` from the shipped
template, then start the stack:

```bash
cp .env.example .env
docker compose up --build
```

The Compose project is named `tracedown`, which is where the network name
`tracedown_tracedown-net` and the volume prefixes come from. You can run it from
anywhere with `docker compose -f path/to/docker/docker-compose.yml up --build`.

Startup is strictly ordered, and each step gates the next on a real condition
rather than a sleep:

1. **`tracedown-postgres`** comes up and passes a `pg_isready` healthcheck.
2. **`tracedown-migrator`** runs Flyway to completion and exits. Every service
   that touches the database waits on
   `condition: service_completed_successfully`, so no service can ever observe
   a half-migrated schema. See [Database & Migrations](database.md).
   (email-service holds no database and gates only on Redis.)
3. **`tracedown-ca-init`** runs `./bin/api-gateway --agent-bootstrap dev-agent`
   once. Its real job is to force the internal certificate authority's root key
   into existence: the scheduler needs a CA to mint its own client certificate
   at startup, so the CA must exist before anything agent-facing boots. See
   [Certificate Authority](../admin/certificate-authority.md).
4. **`tracedown-gateway`** starts and is polled on
   `wget http://localhost:20714/ping`. **ingestor, dispatcher, email, metrics,
   worker and realtime** start in parallel with it as soon as their own gates
   clear.
5. **the scheduler** starts once the gateway is healthy — it is the one service
   that waits for it.

If the run stalls, it is almost always at step 2 or step 4 —
[Troubleshooting](../admin/troubleshooting.md) covers the usual causes.

### What gets published

There is no reverse proxy in the stack. Three services publish directly, each
bound to **127.0.0.1 only**, plus a Postgres mapping for development
convenience (`5555:5432` — an affordance, not a feature; remove it on any host
you do not trust):

| Port | Service | Serves |
|---|---|---|
| `${GATEWAY_PORT}` (20714) | api-gateway | REST API (`/api/v1`), health (`/ping`) |
| `${REALTIME_PORT}` (20870) | realtime-service | WebSocket (`/ws`) |
| `${METRICS_PORT}` (20850) | metrics-service | Prometheus scrape endpoint |

Exposing the stack beyond localhost is a host web server's job — the
[Production Deploy](deploy.md) page and the shipped
`docker/deploy/nginx.conf` / `apache.conf` cover that.

### What the `.env` gives you

The Compose file reads `docker/.env`, which you created above from the shipped
`.env.example` — working development values:

| Variable | Shipped value | Notes |
|---|---|---|
| `DB_NAME` / `DB_USER` / `DB_PASSWORD` | `tracedown` | Postgres credentials. |
| `PLATFORM_AES_KEY` | `0123456789abcdef…` (64 hex chars) | Encrypts variables and TOTP secrets. |
| `JWT_SECRET` | `dev-jwt-secret-change-me-for-prod` | Signs session tokens. |
| `GATEWAY_PORT` / `REALTIME_PORT` / `METRICS_PORT` | `20714` / `20870` / `20850` | The three published (localhost-only) ports. |
| `REDIS_A_URL` / `REDIS_B_URL` / `REDIS_C_URL` | all `redis://tracedown-redis-a:6379` | One instance, three roles. |

Two of these deserve explanation. `PLATFORM_AES_KEY` is the key your encrypted
variables are written under; change it after data exists and that data stops
being readable — only the org data-encryption keys can be moved onto a new key
afterwards, and only with the old key in hand — which is why it belongs in
[Secrets](../admin/secrets.md) rather than in a hurried edit later. And the three Redis URLs all pointing at one
instance is the intended default — the role split between operational,
cache, and hierarchy-cache Redis lives at the URL layer, so a single instance
serves all three until your volume justifies splitting them.
[Architecture](architecture.md) explains the roles;
[Scaling](../admin/scaling.md) covers when to separate them.

The port number is `20714` because it spells "t7n". There is no other
significance to it, and `GATEWAY_PORT` moves it.

??? note "Running on a small host"
    An opt-in overlay caps every container to approximate a small production
    VM (roughly 8 vCPU / 7 GB for the whole stack):

    ```bash
    docker compose -f docker-compose.yml -f docker-compose.limits.yml up -d
    ```

    It sets `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=60` so each JVM sizes its
    heap from the container cap instead of the default 25%, and gives each
    service an explicit `DB_POOL_SIZE`. [Scaling](../admin/scaling.md) has the
    details and the per-service numbers.

!!! note "TimescaleDB is a convenience, not a dependency"
    The Compose file pulls `timescale/timescaledb:latest-pg16`, but Tracedown
    creates no hypertables and needs no extensions — stock PostgreSQL 16 works.
    If you keep the TimescaleDB image, keep `TS_TUNE_MAX_CONNS: "100"` with it.
    Its tuner derives `max_connections` from host memory at initdb, and on a
    small host it lands below what the pools need (55 connections at the
    defaults — see [Configuration](configuration.md#common-to-most-services)),
    so the stack cannot finish booting.

## 2. Log in

`SINGLE_ORG_MODE=true` makes the gateway bootstrap a default organization and a
demo user the first time it starts against an empty database. It is **off by
default**; this Compose file sets it explicitly, which is why the local stack
gives you an account without being asked.

| Setting | Default |
|---|---|
| `DEMO_USER_EMAIL` | `admin@tracedown.dev` |
| `DEMO_USER_PASSWORD` | `Down2trace!` |

This is the only path in Tracedown that creates a user — everyone after the
first is invited from inside the app — so it is also how a production install
gets its first owner. There it works differently, and deliberately so: see
[The first account](configuration.md#the-first-account).

!!! danger "Change these before anyone else can reach the host"
    These credentials are published in this documentation and in the source.
    Override both variables before first start, or change the password
    immediately after logging in. With `DEPLOYMENT_ENV=production` the gateway
    will not start on them at all.

## 3. Enrol a probe agent

Nothing probes until at least one agent is enrolled. The stack has no built-in
executor: the scheduler dispatches work to agents, and with none registered your
services will sit there scheduled and never run.

From `core/tracedown-core-backend`, with the gateway healthy:

```bash
./scripts/bootstrap-agent.sh          # slug defaults to dev-agent
./scripts/bootstrap-agent.sh eu-west  # or name it
```

The script checks that `tracedown-gateway` reports healthy, generates a
single-use bootstrap token through the gateway CLI, builds the agent image from
`core/tracedown-probe-agent/`, and `docker run`s it on the
`tracedown_tracedown-net` network so it can reach the gateway by container name.
The agent uses the token once to submit a certificate signing request, and from
then on authenticates with the resulting CA-signed certificate — the token is
not a long-lived credential.

If the container already exists the script fast-paths: it restarts it, or
reconnects it to the network first if Compose regenerated the network under a
new ID (which a `down`/`up` cycle does). It only regenerates a token and
rebuilds when there is no container to reuse.

The agent takes about a minute to report healthy, because health is established
by an actual health challenge rather than a liveness ping. [Probe
Agents](agents.md) covers enrolment, certificate renewal, storage backends, and
running agents on other hosts.

## 4. Run the dashboard

The dashboard is a separate repository, `core/tracedown-core-frontend`, with its
own `docker/` directory. It does not come up with the backend stack.

=== "Development (Vite)"

    ```bash
    npm install
    npm run dev
    ```

    Vite serves on port 5173. The app calls its production defaults —
    same-origin `/api/v1` and `/ws` — and the dev server's proxy forwards them
    to the backend's published localhost ports (`/api` to the gateway on
    20714, `/ws` to realtime on 20870), so there is no CORS involved and
    nothing to configure. `VITE_WS_MAX_RETRIES` (default 5) sets WebSocket
    reconnect attempts before falling back to polling; `0` disables the
    WebSocket entirely.

=== "Docker (nginx)"

    From `core/tracedown-core-frontend/docker/`:

    ```bash
    docker compose up -d --build
    ```

    This builds the SPA and serves it from its own nginx on
    `${FRONTEND_PORT:-8088}`. The container joins the backend's
    `tracedown_tracedown-net` as an external network — override with
    `BACKEND_NETWORK` if your Compose project name differs — and proxies `/api/`
    to the gateway and `/ws` to realtime-service itself, so the browser only
    ever talks to one origin and there is no CORS involved.

The endpoints are configurable at **container start**, not just build time: the
image regenerates the SPA's `/config.js` from the `API_URL`, `WS_URL`, and
`WS_MAX_RETRIES` environment variables on every start, so one built image can
point at any backend without rebuilding. Unset, the bundle's same-origin
defaults (`/api/v1`, `/ws`) apply — which is the right answer here, since the
frontend's nginx proxies both paths itself. (`VITE_*` build args still exist
for baking different defaults into the bundle, but you should rarely need
them.)

!!! note "`APP_URL` is separate, and easy to forget"
    The backend's `APP_URL` defaults to `http://localhost:5173` and is the base
    URL used to build links in outgoing emails — invitations and password
    resets. It has nothing to do with where the dashboard is actually served
    from, so if you serve the dashboard anywhere other than the Vite dev port,
    set `APP_URL` to match or your users will receive links to a host that does
    not exist. See [Configuration](configuration.md).

The Compose stack sets `EMAIL_PROVIDER=console` for both the gateway and
email-service, so no mail leaves the machine — emails are written to the
container logs. That makes the invite and reset flows testable offline; wiring a
real provider is covered in [Configuration](configuration.md).

## 5. Verify it works

```bash
curl http://localhost:20714/ping     # liveness — the process is serving
curl http://localhost:20714/health   # readiness — its database and Redis answer
docker compose ps
```

Every service answers both on its own port, and `/health` is the one that tells
you *why* something is wrong — but only the three ports above are published, so
reach the rest from inside the network
(`docker compose exec tracedown-ingestor wget -qO- http://localhost:20820/health`).
[Monitoring Tracedown](../admin/observability.md#health-endpoints) lists the
ports and what each service checks.

Every application service should be `running`, and `tracedown-migrator` and
`tracedown-ca-init` should show as exited — those two are meant to run once and
stop. Then log in, and follow the [User Manual](../guide/index.md) to create
your first service and probe.

## Resetting

```bash
docker compose down          # stop, keep data
docker compose down -v       # stop and destroy the volumes
```

The stack keeps three named volumes: `tracedown-pgdata` (all Postgres data),
`tracedown-redis-a-data` (Redis A's AOF), and `tracedown-bodies` (saved response
bodies, mounted into the gateway at `/data/bodies` and into the agent at the
same path, which is how a body written by an agent is later served by the
gateway).

`down -v` destroys all three, including your organization and every recorded
result. The migrator will rebuild the schema from scratch on the next start, and
the gateway will bootstrap the demo user again. Note that the agent container is
not Compose-managed, so `down -v` leaves it behind — re-run
`./scripts/bootstrap-agent.sh` afterwards, which will regenerate a token now
that the CA it was signed against is gone.
