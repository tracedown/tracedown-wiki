# Production Deploy (release artifacts)

The deploy stack in `core/tracedown-core-backend/docker/deploy/` runs the whole
platform — backend services **and** the frontend — from published GitHub
releases. Nothing is built from source: a one-shot fetcher container downloads
each service's jar, the schema-migrator distribution, and the frontend bundle,
pinned by version or tracking latest. This is the intended production setup for
the full, agent-capable edition. (For the smallest installs, the
[monolith](monolith.md) is one jar instead of this stack.)

Unlike the [Quickstart](quickstart.md) stack, this one runs with
`DEPLOYMENT_ENV=production` and **refuses to start on placeholder secrets** —
you must set real ones first.

## 1. Configure

You only need the `docker/deploy/` directory — copy it to the host (say,
`/opt/tracedown/deploy/`). Then:

```bash
cp .env.example .env
```

Work through the file — it is the full configuration scope with the built-in
defaults shown — but three variables in the REQUIRED section gate startup:

| Variable | What |
|---|---|
| `DB_PASSWORD` | Postgres password, also used by the bundled postgres container. |
| `PLATFORM_AES_KEY` | 64 hex chars (`openssl rand -hex 32`). Encrypts the CA root key, org data-encryption keys, variables and TOTP secrets. **Set once, permanent** — it cannot be rotated, and losing it orphans all encrypted data. Back it up separately from the database. |
| `JWT_SECRET` | Session signing secret (`openssl rand -base64 48`). |

Set `APP_URL` to the address your users' browsers will actually reach — it is
the base for links in outgoing email. Versions are pinned by
`BACKEND_VERSION` / `FRONTEND_VERSION`; `latest` resolves the newest release at
first start, exact tags give you reproducible deploys.

## 2. Start

```bash
docker compose up -d
```

The fetcher downloads the artifacts (and unpacks the frontend bundle to
`./frontend-dist`), the migrator applies the schema, and the services come up
in dependency order. The stack publishes exactly three ports, all bound to
**127.0.0.1 only**:

| Port | Service | Serves |
|---|---|---|
| `20714` | api-gateway | REST API (`/api/v1`), health (`/ping`) |
| `20870` | realtime-service | WebSocket (`/ws`) |
| `20850` | metrics-service | Prometheus scrape endpoint |

Everything else talks on the internal Docker network and publishes nothing.

## 3. Expose it with your web server

Exposure to the world is the host web server's job, not the stack's. The
directory ships a ready `nginx.conf` and `apache.conf`; copy the one for your
server into its config, adjust `server_name`/`ServerName` and the path to
`frontend-dist`, and reload. The config serves the frontend bundle as static
files and proxies by path: `/api/` and `/ping` to the gateway, `/ws` to
realtime as a WebSocket upgrade, `/metrics/` to the metrics service. The
frontend calls same-origin `/api/v1` and `/ws`, so no CORS is involved and no
frontend configuration is needed.

!!! warning "The shipped configs are HTTP-only on purpose"
    TLS termination is yours. Once the vhost works over plain HTTP, run
    certbot (`--nginx` / `--apache`) or install your internal certificates.
    Do not put this on the open internet without TLS — sessions and probe
    credentials travel through it.

## 4. Enrol an agent

Nothing probes without at least one [probe agent](agents.md). The agent ships
as a Docker image (`tracedown/tracedown-probe-agent`) and a pip package;
enrolment is a one-time bootstrap token from the gateway CLI, after which the
agent holds a CA-signed certificate. [Probe Agents](agents.md) covers the
whole flow, including agents on other hosts and regions.

## Upgrading

Bump `BACKEND_VERSION` / `FRONTEND_VERSION` in `.env`, then
`docker compose up -d`. The fetcher re-downloads, the migrator applies any
pending migrations before a single service starts, and the services restart on
the new jars. [Upgrading](../admin/upgrading.md) covers rollbacks and the
backup you should take first.
