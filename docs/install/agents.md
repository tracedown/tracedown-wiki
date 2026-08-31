---
description: "Deploy Tracedown probe agents: a stateless Python FastAPI service that runs Lace scripts, enrols over mTLS with a bootstrap token, and is health-checked."
---
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
`PROBE_AGENT_` prefix. The deployment environment is the one exception: it
answers to its unprefixed, platform-wide name as well.

| Variable | Purpose | Default |
|---|---|---|
| `PROBE_AGENT_BOOTSTRAP_TOKEN` | One-time token from `--agent-bootstrap` | `""` |
| `PROBE_AGENT_SCHEDULER_URL` | Base URL for registration and renewal | `""` |
| `PROBE_AGENT_BOOTSTRAP_CA_BUNDLE` | PEM bundle of the CA that issued the gateway's certificate, used to authenticate it at enrolment | `""` |
| `PROBE_AGENT_BOOTSTRAP_PIN_SHA256` | SHA-256 fingerprint(s) of the certificate the gateway presents, pinned at enrolment; takes precedence over the bundle | `""` |
| `PROBE_AGENT_INSECURE_SKIP_BOOTSTRAP_TLS_VERIFY` | Skips verification of the gateway's certificate at enrolment; refused in production | `false` |
| `PROBE_AGENT_DEPLOYMENT_ENV` | Deployment environment; `production` refuses unauthenticated enrolment. Read unprefixed as `DEPLOYMENT_ENV` too | `dev` |
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
| `PROBE_AGENT_STORAGE_BACKEND` | `filesystem` or `s3` | `filesystem` |
| `PROBE_AGENT_STORAGE_DIR` | Body directory for the filesystem backend | `/data/bodies` |
| `PROBE_AGENT_S3_ENDPOINT_URL` | S3-compatible endpoint (AWS S3, Cloudflare R2, MinIO, …), `s3` backend only | `""` |
| `PROBE_AGENT_S3_ACCESS_KEY_ID` | Access key, `s3` backend only | `""` |
| `PROBE_AGENT_S3_SECRET_ACCESS_KEY` | Secret key, `s3` backend only | `""` |
| `PROBE_AGENT_S3_BUCKET` | Bucket, `s3` backend only | `""` |
| `PROBE_AGENT_S3_PREFIX` | Key prefix within the bucket, `s3` backend only | `""` |
| `PROBE_AGENT_S3_REGION` | Bucket region — `auto` suits R2 and is ignored by MinIO; AWS S3 wants the real one | `auto` |

!!! note "`SCHEDULER_URL` points at the gateway"
    The name is historical. Registration and renewal are served by the
    **api-gateway** on `/internal/agents/register` and `/internal/agents/renew`,
    so the value in practice is the gateway's base URL — in the Compose stack,
    `http://tracedown-gateway:20714`. Point it at the scheduler and bootstrap
    fails. The scheme matters as much as the host — see [Authenticating the
    gateway at enrolment](#authenticating-the-gateway-at-enrolment).

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
5. Authenticates the gateway, then POSTs `{bootstrapToken, csrPem, agentUri}` to
   `{scheduler_url}/internal/agents/register` with a 30-second timeout. Over
   `https://` the gateway's certificate is verified against the system trust
   store by default; a private CA or a self-signed certificate takes one
   variable. Nothing is sent to a peer the agent could not authenticate — see
   [Authenticating the gateway at
   enrolment](#authenticating-the-gateway-at-enrolment).
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

### Authenticating the gateway at enrolment

Registration is the agent's only unauthenticated moment, and it is the one that
matters most: that single POST carries the bootstrap token *and* receives the CA
bundle the agent pins for the rest of its life. Whoever answers it owns the agent
from then on — an on-path attacker reads the token and installs a CA of their
own. So the agent authenticates the gateway before the token leaves the process,
and a configuration that cannot authenticate it fails registration rather than
sending the token anyway.

Over `https://` there are three ways to do that, in order of preference:

| Situation | What to set |
|---|---|
| Gateway behind a publicly trusted certificate (certbot, a managed edge) | Nothing — the system trust store is the default |
| Gateway behind a private or internal CA | `PROBE_AGENT_BOOTSTRAP_CA_BUNDLE=/path/to/ca.pem` |
| Gateway certificate chains to nothing (self-signed) | `PROBE_AGENT_BOOTSTRAP_PIN_SHA256=<fingerprint>` |
| Local development only | `PROBE_AGENT_INSECURE_SKIP_BOOTSTRAP_TLS_VERIFY=true` |

Take the fingerprint from whoever runs the gateway, the same way you take the
bootstrap token — both have to reach you out of band anyway:

```bash
openssl s_client -connect tracedown.example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
```

Colons, a `sha256:` prefix, and several comma- or space-separated values are all
accepted. The agent opens one throwaway handshake to read the certificate the
gateway presents, refuses to go any further unless it matches a pin, and then
makes the registration request trusting that certificate and nothing else — so
there is no gap between checking and using. A malformed pin fails before a
connection is opened at all, and a pin wins over a CA bundle when both are set.

`PROBE_AGENT_INSECURE_SKIP_BOOTSTRAP_TLS_VERIFY` is the only way to reach an
unverified connection — nothing else in the agent can — and it logs a warning
every time it is used.

!!! warning "A plain `http://` gateway URL sends the token in the clear"
    There is no transport to authenticate: the bootstrap token crosses the wire
    unencrypted, and so does the CA bundle coming back. This is what every
    shipped stack does — `bootstrap-agent.sh`, the dashboard's connect command
    and the installer all set
    `PROBE_AGENT_SCHEDULER_URL=http://tracedown-gateway:20714` — because there
    the agent and the gateway share a private Docker network. That is the only
    setting in which it is acceptable, and the agent logs a warning each time.
    On any path you do not control, enrol over `https://`.

Both the opt-out and plain `http://` are **refused when
`DEPLOYMENT_ENV=production`**: registration raises and the agent does not come
up. Only that exact value arms the guard — anything else, unset included, counts
as development, and the agent's own default is `dev`. It is read unprefixed as
well as as `PROBE_AGENT_DEPLOYMENT_ENV`, so a stack that already sets it
platform-wide needs nothing extra; note that agents run as their own containers,
so the [deploy stack](deploy.md)'s `.env` does not reach them unless you pass it.

#### Reaching enrolment over https

`/internal/agents/register` and `/internal/agents/renew` are mounted at the
**gateway root**, not under `/api/`, so a proxy that only forwards `/api/` lands
an agent's registration on the SPA fallback and answers it with the dashboard's
`index.html`.

The `nginx.conf` and `apache.conf` shipped in `docker/deploy/` proxy them, so an
agent pointed at your public `https://tracedown.example.com` enrols with nothing
further to configure. Three paths are published, one rule each:

| Path | Why it is reachable from outside |
|---|---|
| `/internal/agents/register` | Carries a single-use bootstrap token you issued, valid for an hour. Being reachable is the whole point of an enrolment endpoint. |
| `/internal/agents/renew` | Gated on proof of possession of the agent's existing private key, not on a token. |
| `/internal/health/token/{challengeId}` | Returns a 32-byte token with a 30-second TTL, under an unguessable challenge id the scheduler minted and handed to one named agent over mTLS. The token means something only to the scheduler that issued it, against that one agent's challenge. |

What TLS adds on top is the confidentiality and the peer authentication the
bootstrap token cannot provide for itself.

The third path is there because a remote agent has to fetch its health-challenge
token from the gateway, and it fetches it from whatever URL the scheduler puts in
the challenge — which is `GATEWAY_URL` plus that path. For an agent off the
Docker network, `GATEWAY_URL` therefore has to be the public https URL, not the
internal one the shipped `.env.example` sets.

Leave it internal and the failure is quiet and misdirected: enrolment succeeds,
the agent appears in the UI, and then every challenge fails on a URL only the
scheduler can resolve. Because the scheduler *can* reach it, the round is not
excused as inconclusive — it counts against the agent, and the agent is marked
down (`agent_down`) after two of them. See [Agent
health](../admin/observability.md#agent-health).

!!! warning "Do not replace those rules with an `/internal/` catch-all"
    The shipped configs list the three paths one at a time on purpose.
    Everything else the gateway serves under `/internal/` is for the internal
    Docker network, and a future addition there would be published to the
    internet by an over-broad rule rather than by a deliberate decision in your
    vhost.

If your own reverse proxy predates these rules, or you wrote it by hand, copy
them across:

=== "nginx"

    ```nginx
    location = /internal/agents/register {
        proxy_pass http://127.0.0.1:20714;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /internal/agents/renew {
        proxy_pass http://127.0.0.1:20714;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # ^~ so this prefix wins over the SPA fallback without regex locations
    # getting a look in. The trailing segment is the challenge id.
    location ^~ /internal/health/token/ {
        proxy_pass http://127.0.0.1:20714;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    ```

=== "Apache"

    ```apache
    ProxyPass        /internal/agents/register http://127.0.0.1:20714/internal/agents/register
    ProxyPassReverse /internal/agents/register http://127.0.0.1:20714/internal/agents/register
    ProxyPass        /internal/agents/renew http://127.0.0.1:20714/internal/agents/renew
    ProxyPassReverse /internal/agents/renew http://127.0.0.1:20714/internal/agents/renew
    ProxyPass        /internal/health/token/ http://127.0.0.1:20714/internal/health/token/
    ProxyPassReverse /internal/health/token/ http://127.0.0.1:20714/internal/health/token/
    ```

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

### Encrypting the payload in flight

A dispatch carries the Lace script and every resolved variable for that service,
secrets included. Mutual TLS already closes that to the network. What it does
not close is a hop that *terminates* TLS on the way — an ingress, a managed
edge, a tunnel — because such a hop decrypts, reads and re-encrypts.

Turning **Encrypt payload in flight** on for an agent (Settings → Agents, expand
the agent) seals the job body to that agent's own certificate before it reaches
the TLS layer: a random AES-256-GCM key encrypts the body, and that key is
wrapped with RSA-OAEP-256 to the public key in the certificate the gateway
issued the agent. The private key never left the agent, so only that agent can
unwrap it, and a terminating hop sees an opaque envelope. The reply comes back
the same way, sealed to the scheduler's certificate.

It is a per-agent setting because the exposure is a property of the path, not of
the platform. An agent on the same private network as the scheduler gains
nothing, and sealing is not free — each run costs an RSA operation at both ends.
Turn it on for the agents you reach through something that terminates TLS, and
leave the rest alone. It is off by default.

Both ends must be current. The agent reports whether it can open a sealed
dispatch as part of its [health challenge](#health-challenges), and the
dashboard will not arm the toggle for an agent that says it cannot — upgrade the
agent and the setting becomes available after its next challenge. If an agent is
downgraded *after* the toggle was armed, the scheduler logs a warning and
dispatches unsealed rather than failing the probe: monitoring keeps running, and
the warning is the signal to fix it.

!!! note "What this does not buy you"
    It is not protection against a compromised agent. The agent has to decrypt
    the payload to run the probe at all, so whoever owns the agent owns the
    script and the variables however they arrived. Nor is it a data-residency
    control — it changes how the payload travels, not where it is executed or
    where the bodies it saves are stored.

The whole mechanism can be switched off from the scheduler's environment with
`PROBE_PAYLOAD_ENCRYPTION_ENABLED=false`; see
[Configuration](configuration.md). That is a kill switch and nothing more — it
cannot turn sealing *on* for an agent that has not been set to it.

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
`fail`, `wrong_token`, `timeout` (10-second budget), or `inconclusive` — the
last when the round could not be completed for reasons that are the platform's
rather than the agent's.

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

**Two consecutive** non-passing rounds mark the agent failed and raise an
agent-down alert. One is treated as a blip and changes nothing, and a single
pass puts a failed agent straight back into rotation. A round trip over
**1200 ms** on an otherwise passing challenge marks the agent degraded and
raises an alert of its own. Results are also written to the agent health history
and pushed live to the dashboard. What each result means, and when a round is
discounted as inconclusive, is covered in [Monitoring
Tracedown](../admin/observability.md#agent-health).

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
(consecutive, simultaneous, or random) is a per-service setting, as is what
happens when the chosen agent will not take the job; see
[Services](../guide/services.md#probe-agents).

## Body storage

When a probe saves a response body, the agent writes it through the configured
backend. `filesystem` writes under `storage_dir` (`/data/bodies` by default) and
is the right choice when agents share a volume with the stack or when bodies are
not worth keeping beyond the retention window. Set `storage_backend=s3` and the
`PROBE_AGENT_S3_*` variables to push bodies to any S3-compatible object
storage instead,
which is what you want once agents are geographically spread and no shared
filesystem exists.

Body saving is off unless a script asks for it, and the scheduler can forbid it
per job regardless of what the script requests. See
[Configuration](configuration.md).
