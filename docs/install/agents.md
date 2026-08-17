# Probe Agents

A probe agent is the thing that actually makes the HTTP requests. Everything
else in Tracedown decides *what* to run and *when*, records *what happened*, and
tells you about it. The agent is the only component that touches the endpoint
you are monitoring, which is why it is the only component you deploy more than
once and in more than one place.

Agents belong to the per-service deployment. The [monolith](monolith.md)
executes probes in-process with an embedded executor instead — it uses no
agents, and nothing on this page applies to it.

The agent lives in `core/tracedown-probe-agent`. It is a Python FastAPI service
(Python 3.10+, shipped as `python:3.12-slim`) that wraps the Lace executor. Its
dependencies are deliberately small: `fastapi`, `uvicorn[standard]`, `httpx`,
`cryptography>=44`, `boto3`, and the `lacelang-validator` / `lacelang-executor`
pair.

## The agent is stateless

The scheduler sends the agent a job containing a Lace `script`, the fully
resolved `variables` for that service, and the `prev` result if the script needs
it. The agent runs the script and returns the raw ProbeResult JSON. That is the
entire contract.

The agent does not know the job ID, the service, the project, or the
organization the probe belongs to — the scheduler correlates the response with
the request because it made the request. It stores no monitoring state, keeps no
queue, and has no database. The only durable state on an agent is its own
identity: three PEM files, a CA-pin file, and a slug file under `/certs`.

Alongside the script, variables and previous result, a job carries two
platform controls: `allowBodySave`, with which the scheduler can forbid body
persistence for that run regardless of what the script asks, and the plaintext
secret values in play, which the agent masks out of any body it saves before
the body is written.

This is what makes agents disposable. An agent that is destroyed and rebuilt
loses nothing except its certificate, and a bootstrap token re-issues that in
seconds. It also means you can scale probing capacity by adding agents without
coordinating anything between them.

## The scheduler dials the agent

!!! warning "The agent must be reachable *inbound* from the scheduler"
    Work flows from scheduler to agent, not the other way round. The scheduler
    opens a mutual-TLS connection to the agent's URI and POSTs the job. The
    agent never polls for work; its only outbound platform calls are
    registration and certificate renewal, and those go to the api-gateway, not
    the scheduler.

    An agent behind NAT, a firewall, or a private network with no inbound route
    from the scheduler will bootstrap successfully, appear in the dashboard, and
    then sit there receiving nothing. Registration passing is not evidence that
    dispatch will work — registration is an *outbound* call to the gateway,
    dispatch is an *inbound* call from the scheduler. This is the single most
    common deployment mistake.

The URI the scheduler dials is the one the agent reported at registration:
`https://{socket.getfqdn()}:{port}` — https, because dispatch is mutual TLS. If
the agent's FQDN inside its container is not a name the scheduler can resolve
and route to, that URI is wrong and nothing will reach it.

## Configuration

Every setting is read from the environment by pydantic-settings with the
`PROBE_AGENT_` prefix.

| Variable | Purpose | Default |
|---|---|---|
| `PROBE_AGENT_BOOTSTRAP_TOKEN` | One-time token from `--agent-bootstrap` | `""` |
| `PROBE_AGENT_SCHEDULER_URL` | Base URL for registration and renewal | `""` |
| `PROBE_AGENT_CA_CERT_PATH` | CA trust bundle written at bootstrap | `/certs/ca.pem` |
| `PROBE_AGENT_CERT_PATH` | Signed agent certificate | `/certs/agent.pem` |
| `PROBE_AGENT_KEY_PATH` | Agent private key | `/certs/agent-key.pem` |
| `PROBE_AGENT_CA_PINS_PATH` | CA fingerprint pin file (trust-on-first-use) | `/certs/ca-pins.txt` |
| `PROBE_AGENT_SLUG_PATH` | Persisted slug, read at renewal | `/certs/agent-slug.txt` |
| `PROBE_AGENT_SLUG` | Overrides the persisted slug | `""` |
| `PROBE_AGENT_RENEW_BEFORE_DAYS` | Renew when the cert is within N days of expiry | `30` |
| `PROBE_AGENT_RENEW_CHECK_HOURS` | Renewal check interval | `24` |
| `PROBE_AGENT_HOST` | Listen address | `0.0.0.0` |
| `PROBE_AGENT_PORT` | Listen port, also used in the self-reported URI | `8443` |
| `PROBE_AGENT_LOG_LEVEL` | uvicorn log level | `info` |
| `PROBE_AGENT_MAX_CONCURRENCY` | Probe thread pool size | `256` |
| `PROBE_AGENT_STORAGE_BACKEND` | `filesystem` or `r2` | `filesystem` |
| `PROBE_AGENT_STORAGE_DIR` | Body directory for the filesystem backend | `/data/bodies` |
| `PROBE_AGENT_R2_ENDPOINT_URL` | R2 endpoint, `r2` backend only | `""` |
| `PROBE_AGENT_R2_ACCESS_KEY_ID` | R2 access key, `r2` backend only | `""` |
| `PROBE_AGENT_R2_SECRET_ACCESS_KEY` | R2 secret, `r2` backend only | `""` |
| `PROBE_AGENT_R2_BUCKET` | R2 bucket, `r2` backend only | `""` |
| `PROBE_AGENT_R2_PREFIX` | Key prefix within the bucket, `r2` backend only | `""` |

!!! note "`SCHEDULER_URL` points at the gateway"
    The name is historical. Registration and renewal are served by the
    **api-gateway** on `/internal/agents/register` and `/internal/agents/renew`,
    so the value in practice is the gateway's base URL — in the Compose stack,
    `http://tracedown-gateway:20714`. Point it at the scheduler and bootstrap
    fails.

### Why `MAX_CONCURRENCY` defaults to 256

Probes block on network I/O — DNS, TCP connect, TLS handshake, time-to-first-byte,
transfer — so they run in a thread pool rather than on the event loop. Python's
default asyncio executor is only `min(32, cpu_count + 4)` threads. When you probe
over the public internet each probe pays a full handshake and takes on the order
of half a second to a second, so 32 threads cap you at a few dozen probes per
second no matter how much CPU the box has. The pool is I/O-bound, not CPU-bound,
so it can be far larger than the core count.

Size it as `peak_rps × avg_probe_seconds`, with headroom. If your fleet fires 200
probes at the top of each minute and each takes 800 ms, you need roughly 160
in-flight slots; the default of 256 covers that. See
[Scaling](../admin/scaling.md).

## Bootstrap and registration

Registration is a single round trip that happens at most once per agent
lifetime. On startup, if `bootstrap_token` **and** `scheduler_url` are both set
and the certificate and key files do not already exist, the agent:

1. Generates an RSA-4096 keypair.
2. Writes the private key to `key_path` as unencrypted PKCS#8 PEM. The key never
   leaves the agent — only the CSR does.
3. Builds a PKCS#10 CSR with subject `O=tracedown-agent`.
4. Determines its own URI as `https://{socket.getfqdn()}:{port}`.
5. POSTs `{bootstrapToken, csrPem, agentUri}` to
   `{scheduler_url}/internal/agents/register`, with a 30-second timeout and TLS
   verification disabled — at this moment the agent has no CA to verify against,
   which is exactly what it is asking for. Run this over a trusted network.
6. Writes the returned `certificatePem` to `cert_path`, `caRootPem` to
   `ca_cert_path`, and the assigned `slug` to `slug_path`.
7. Records SHA-256 fingerprints of the received CA bundle in `ca_pins_path`.

That last step is trust-on-first-use pinning, and it is what protects every
later renewal. When the agent renews, the gateway hands it the current CA
bundle again — but the agent **refuses** a bundle that shares no fingerprint
with what it pinned at bootstrap, on the grounds that a wholesale swap of the
trust anchor looks like a man-in-the-middle rather than a rotation. A
legitimate [CA rotation](../admin/certificate-authority.md) keeps the old CA in
the bundle during the overlap, so the pins advance naturally with each renewal.

If the certificate and key already exist, bootstrap is skipped entirely and the
token is ignored. That check is what makes the container restart-safe: you can
leave `PROBE_AGENT_BOOTSTRAP_TOKEN` in the environment forever, restart as often
as you like, and the agent will not re-register — as long as `/certs` is on a
volume that survives the restart. If it is not, every restart needs a fresh
token, because tokens are single-use.

### Creating a bootstrap token

=== "CLI"

    ```bash
    ./bin/api-gateway --agent-bootstrap <slug> [--label <label>]
    ```

    The slug is the agent's stable identifier; `--label` is a human-readable
    name that defaults to the slug. The token is printed once and cannot be
    retrieved again.

=== "Dashboard"

    Settings → Agents → connect. Same token, same rules.

The token is 32 random bytes rendered as 64 hex characters. It is stored only as
a bcrypt hash (cost 12), expires **1 hour** after creation, and is **single
use**. Losing it costs nothing — generate another. Leaking it lets someone else
enrol an agent under that slug within the hour.

Creating the first token also creates the CA root, which is why the Compose stack
runs a dedicated `tracedown-ca-init` step before the gateway. See
[Certificate Authority](../admin/certificate-authority.md).

## Running an agent

For a local stack, `bootstrap-agent.sh` in `core/tracedown-core-backend` does the
whole dance:

```bash
./scripts/bootstrap-agent.sh [slug]     # slug defaults to dev-agent
```

When it needs a fresh bootstrap it refuses to run unless `tracedown-gateway`
reports healthy, because a token cannot be minted without the gateway and the
CA — though the fast path for an existing container (below) runs before that
check, so a plain restart succeeds even with the gateway down. For a fresh
bootstrap it generates a token via
`docker compose run --rm tracedown-gateway ./bin/api-gateway --agent-bootstrap`,
rebuilds the agent image with `--no-cache`, and `docker run`s the container on
network `tracedown_tracedown-net` with the token, `PROBE_AGENT_SCHEDULER_URL`
set to `http://tracedown-gateway:20714`, and the shared bodies volume mounted at
`/data/bodies`.

If the container `tracedown-agent-<slug>` already exists the script takes a fast
path instead: it compares the network ID the container is attached to against the
live network of that name, and either just `docker start`s it, or reconnects it
to the regenerated network first (which is what you want after a
`docker compose down`/`up` cycle) — no new token, no rebuild. If the backend
network is gone entirely it errors out and tells you to start the backend.

The agent will show as healthy after the first health challenge lands, roughly a
minute later.

### The certificate is the authorization

Once a certificate is present, the agent serves **mutual TLS** on 8443: the
listener requires a client certificate signed by the internal CA and rejects
any connection that does not present one (`ssl.CERT_REQUIRED`). There is no API
key or bearer token — holding the right CA-signed certificate *is* the
authorization to call `/probe`, and "right" is narrower than mere CA
membership. Certificates are role-pinned by extended key usage: agent
certificates are issued for server authentication only and the scheduler's for
client authentication only, so one agent's certificate can never be replayed as
a client to call another agent's `/probe`. The scheduler goes further on its
side of the handshake — beyond validating the chain it requires the agent
certificate's SAN to match the expected agent slug and checks it against
revocation, failing closed. The certificate's SAN carries the slug rather than
a network address, which has a practical consequence: the scheduler must dial
the agent at a hostname equal to its slug, or TLS hostname verification fails.
This is why the bootstrap script runs the container with `--hostname` and
`--network-alias` set to the slug, and why an agent reached through DNS needs
a record matching its slug.

The agent enters this mode on its first boot: the image runs `python src/main.py`,
which registers and obtains its certificate *before* binding the socket, then
starts the server with the mTLS context. If no bootstrap token is configured and
no certificate exists — a local development scenario — the agent falls back to
plain HTTP and logs that it did so. A failed bootstrap is fatal rather than a
silent fallback, so a production agent never comes up unauthenticated.

Certificate renewal is applied to the running listener without a restart: when
the renewal loop obtains a fresh certificate it reloads it onto the live TLS
context, so new connections serve the new certificate immediately (existing
connections finish on the old one). A self-hosted agent left running for years
rotates its certificate on its own — there is no annual restart to remember.

## Health challenges

The agent exposes two health endpoints:

| Endpoint | Returns |
|---|---|
| `GET /health` | `{status, version, executor_version}` |
| `POST /health/challenge` | `{challenge_id, token, elapsed_ms, success, error}` |

`GET /health` is liveness for a load balancer or orchestrator: it proves the
process is up and answering.

`POST /health/challenge` proves something much stronger. The scheduler generates
a challenge ID and a one-time token, stores the token in Redis with a 30-second
TTL, and POSTs `{challenge_id, token_url}` to the agent. The agent then **runs a
real Lace script** to fetch the token from the gateway and returns whatever it
got back. The scheduler compares it against what it stored and records `pass`,
`fail`, `wrong_token`, or `timeout` (10-second budget).

That round trip exercises the entire path an actual probe uses: the executor
loads and runs, DNS and TCP and HTTP work outbound, the response body is parsed
without corruption, and the result comes back over the same channel a probe
result would. A ping proves only that the process answers sockets — an agent
whose executor is broken, whose DNS is dead, or whose egress is blackholed
answers a ping perfectly and fails every probe silently. The challenge is
therefore a real test of probing capability, not of liveness.

Quartz drives it on cron `30 * * * * ?` — every minute at second :30. The offset
is deliberate. Probe cron schedules all fire at second 0, so a challenge sent at
the same instant queues behind the fleet-wide burst and reports a latency that
reflects the burst rather than the agent. Measuring at :30 keeps the signal
clean.

A round trip over **500 ms** on an otherwise passing challenge marks the agent
degraded and raises an alert; a non-passing result raises an agent-down alert.
Results are also written to the agent health history and pushed live to the
dashboard.

## Removing an agent

```bash
./bin/api-gateway --remove-agent
```

The command takes no arguments and is interactive. It lists every active agent
with its slug, label, last status, and last health check time in an indexed
table, then prompts for a number. `q` cancels; anything that is not a valid
index exits non-zero without touching the database.

Confirming does three things in one transaction: sets `probe_agents.is_active`
to false, marks every non-revoked certificate for that agent revoked with the
reason `"Agent removed via CLI"`, and deletes its `service_allowed_agents`
bindings so no service is left pointing at an agent that will never answer.

Probe history is kept. Removing an agent retires the worker, not the data it
produced — your graphs and incident history stay intact. The dashboard offers
the same action.

## Which agents run a service

A service can restrict itself to a subset of agents — useful when a probe must
originate from a particular network or region. If a service names no agents,
every active, healthy agent is eligible for it. Selection strategy
(consecutive, simultaneous, or random) is a per-service setting; see
[Services](../guide/services.md).

## Body storage

When a probe saves a response body, the agent writes it through the configured
backend. `filesystem` writes under `storage_dir` (`/data/bodies` by default) and
is the right choice when agents share a volume with the stack or when bodies are
not worth keeping beyond the retention window. Set `storage_backend=r2` and the
five `PROBE_AGENT_R2_*` variables to push bodies to object storage instead,
which is what you want once agents are geographically spread and no shared
filesystem exists.

Body saving is off unless a script asks for it, and the scheduler can forbid it
per job regardless of what the script requests. See
[Configuration](configuration.md).
