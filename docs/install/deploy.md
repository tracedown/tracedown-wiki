---
description: "Deploy Tracedown for real from published release artifacts with Docker Compose or one-click Railway, behind your own web server, with real secrets set."
---
# Production Deploy (release artifacts)

The deploy stack in `core/tracedown-core-backend/docker/deploy/` runs the whole
platform — backend services **and** the frontend — from published GitHub
releases. Nothing is built from source: a one-shot fetcher container downloads
each service's jar, the schema-migrator distribution, and the frontend bundle,
pinned by version or tracking latest. This is the intended production setup for
the full, agent-capable edition. (For the smallest installs, the
[monolith](monolith.md) is one jar instead of this stack.)

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/tracedown-core-template?referralCode=htSVme)

Don't want to manage a host? The same stack — all services, Postgres, Redis,
and the dashboard behind an edge proxy — deploys to
[Railway](https://railway.com/deploy/tracedown-core-template?referralCode=htSVme) in one click
with the button above. The rest of this page covers running it on your own
machine.

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
| `PLATFORM_AES_KEY` | 64 hex chars (`openssl rand -hex 32`). Encrypts the CA root key, org data-encryption keys, variables and TOTP secrets. **Set it before first start** — losing it orphans all encrypted data, and moving to a new key later is [only partly a command](../admin/secrets.md#re-keying-an-installation-that-already-holds-data), the rest by hand. Back it up separately from the database. |
| `JWT_SECRET` | Session signing secret (`openssl rand -base64 48`). |

Set `APP_URL` to the address your users' browsers will actually reach — it is
the base for links in outgoing email. Versions are pinned by
`BACKEND_VERSION` / `FRONTEND_VERSION`; `latest` resolves the newest release at
first start, exact tags give you reproducible deploys.

### The first account

Tracedown is invite-only: everyone after the first person is invited from inside
the app, and `--create-org` assigns an organization to a user who already
exists. The very first owner has to come from the stack, and `SINGLE_ORG_MODE`
is the only thing that creates one. It is **off by default**, so decide this
now — before first start, while the user table is still empty:

```bash
# in .env
SINGLE_ORG_MODE=true
DEMO_USER_EMAIL=you@example.com
DEMO_USER_PASSWORD=<a real password — it must pass the password policy>
```

!!! danger "This stack runs as `production`, so the shipped credentials are refused"
    `DEMO_USER_EMAIL` and `DEMO_USER_PASSWORD` have committed defaults
    (`admin@tracedown.dev` / `Down2trace!`) that make a laptop trial work with no
    setup. Under `DEPLOYMENT_ENV=production`, which this stack sets, turning
    `SINGLE_ORG_MODE` on while either is still on its published value makes the
    gateway **refuse to start**, naming what is wrong. The password is checked
    against the password policy too.

    There is no override — `ALLOW_INSECURE_DEV_KEYS` does not lift this one. See
    [The first account](configuration.md#the-first-account).

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
| `20714` | api-gateway | REST API (`/api/v1`), agent enrolment (`/internal/agents/…`), liveness (`/ping`), readiness (`/health`) |
| `20870` | realtime-service | WebSocket (`/ws`) |
| `20850` | metrics-service | Prometheus scrape endpoint |

Everything else talks on the internal Docker network and publishes nothing. Each
of those services answers `/ping` and `/health` on its own internal port, and
Compose uses `/ping` as its container healthcheck — the gateway's gates the
scheduler's start. [Monitoring
Tracedown](../admin/observability.md#health-endpoints) covers what each service
checks and how to read the report.

## 3. Expose it with your web server

Exposure to the world is the host web server's job, not the stack's. The
directory ships a ready `nginx.conf` and `apache.conf`; copy the one for your
server into its config, adjust `server_name`/`ServerName` and the path to
`frontend-dist`, and reload. The config serves the frontend bundle as static
files and proxies by path: `/api/` and `/ping` to the gateway, `/ws` to
realtime as a WebSocket upgrade, `/metrics/` to the metrics service, and three
named paths under `/internal/` to the gateway so that agents on other hosts can
enrol and answer health challenges over https. The frontend calls same-origin
`/api/v1` and `/ws`, so no CORS is involved and no frontend configuration is
needed.

!!! warning "The shipped configs are HTTP-only on purpose"
    TLS termination is yours. Once the vhost works over plain HTTP, run
    certbot (`--nginx` / `--apache`) or install your internal certificates.
    Do not put this on the open internet without TLS — sessions and probe
    credentials travel through it.

## 4. Sign in

With `SINGLE_ORG_MODE=true` set in step 1, the first start created your owner
account. Open the URL you set as `APP_URL` and sign in with the credentials you
put in `.env`.

Then set `SINGLE_ORG_MODE=false` again and `docker compose up -d`. The bootstrap
only ever acts on an empty user table, so leaving it on changes nothing — but it
is one less thing to reason about, and one less way to be surprised later.
Further organizations come from the CLI, against users who already exist:

```bash
docker compose run --rm tracedown-gateway \
  java -jar /artifacts/api-gateway.jar --create-org <name> --owner <email>
```

## 5. Enrol an agent

Nothing probes without at least one [probe agent](agents.md). The agent ships
as a Docker image (`tracedown/tracedown-probe-agent`) and a pip package;
enrolment is a one-time bootstrap token from the gateway CLI, after which the
agent holds a CA-signed certificate. [Probe Agents](agents.md) covers the
whole flow, including agents on other hosts and regions.

An agent that shares the Docker network reaches the gateway directly and needs
nothing from your web server. An agent on another host enrols over your public
https URL, and the shipped vhosts already proxy the three paths that takes —
registration, renewal and the health-challenge token endpoint. The trust
settings the agent needs for that first request are in [Authenticating the
gateway at enrolment](agents.md#authenticating-the-gateway-at-enrolment).

## Upgrading

Bump `BACKEND_VERSION` / `FRONTEND_VERSION` in `.env`, then
`docker compose up -d`. The fetcher re-downloads, the migrator applies any
pending migrations before a single service starts, and the services restart on
the new jars. [Upgrading](../admin/upgrading.md) covers rollbacks and the
backup you should take first.
