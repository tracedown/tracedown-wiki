---
description: "The interactive Tracedown installer: four modes, what each one asks, and the TD_* variables that pre-answer every prompt for unattended installs."
---
# The interactive installer

One command, four modes, and a question at every point where guessing on your
behalf would be wrong:

```bash
curl -fsSL https://tracedown.dev/install.sh | bash
```

It needs `curl`, `openssl`, and — for everything except the Kubernetes mode —
Docker with the Compose plugin. Everything it creates lands in a directory you
choose; nothing outside that directory is touched apart from Docker resources
and, if you explicitly say yes, one nginx vhost.

!!! tip "Read it before you pipe it"
    Piping a script from the internet into a shell deserves the scepticism it
    usually gets. The [source](https://github.com/tracedown/tracedown-install)
    is short and plain, and `https://tracedown.dev/install.sh` is a redirect to
    `main` in that repository — so what you read there is exactly what runs.

## The four modes

| # | Mode | What it stands up | Start here when |
|---|---|---|---|
| 1 | **Monolith** | [The single jar](monolith.md) in one container, plus PostgreSQL and Redis. | You want the smallest real installation. |
| 2 | **Full stack** | [The per-service deployment](deploy.md) — 11 containers from published release artifacts, optionally with the host nginx vhost written and enabled. | You are running it for real. |
| 3 | **Probe agent** | Mints a bootstrap token on an existing full stack and connects [an agent](agents.md) to it. | You are adding a vantage point to a stack you already have. |
| 4 | **Kubernetes** | Generates plain manifests for the monolith and applies them to a context you name. | You already run a cluster. |

Mode 3 is the only one that expects something to already exist. Modes 1, 2 and
4 start from nothing.

## What each mode asks

Every prompt has a default in brackets; pressing enter accepts it. Each one can
also be pre-answered with the environment variable named beside it below — that
is the whole mechanism behind [unattended installs](#unattended-installs).

### Asked by every mode

| Prompt | Variable | Default |
|---|---|---|
| Which mode | `TD_MODE` | `1` |
| Email delivery — `smtp`, or `none` to keep mail in the logs | `TD_EMAIL_MODE` | `none` |
| SMTP host / port / username / password | `TD_SMTP_HOST`, `TD_SMTP_PORT`, `TD_SMTP_USERNAME`, `TD_SMTP_PASSWORD` | port `587` |
| From address | `TD_EMAIL_FROM` | derived from the SMTP host |

The SMTP questions only appear when you answer `smtp`. Choosing `none` is a
real answer, not a deferral — the system runs, and every notification it would
have sent is written to the logs instead.

### Monolith (1)

| Prompt | Variable | Default |
|---|---|---|
| Install directory | `TD_DIR` | `~/tracedown` |
| Backend version, or `latest` | `TD_VERSION` | `latest` |
| Gateway port (dashboard + API) | `TD_GATEWAY_PORT` | `20714` |
| WebSocket port | `TD_REALTIME_PORT` | `20870` |
| Admin login email | `TD_DEMO_EMAIL` | `admin@tracedown.dev` |
| Admin login password | `TD_DEMO_PASSWORD` | `Down2trace!` |

### Full stack (2)

| Prompt | Variable | Default |
|---|---|---|
| Install directory | `TD_DIR` | `~/tracedown` |
| Backend version, or `latest` | `TD_VERSION` | `latest` |
| Public base URL browsers will reach | `TD_APP_URL` | `https://tracedown.example.com` |
| Admin login email | `TD_DEMO_EMAIL` | `admin@tracedown.dev` |
| Admin login password | `TD_DEMO_PASSWORD` | *(none — you must supply one)* |
| Write and enable the nginx vhost? | `TD_HOST_CONF` | `yes` |
| `server_name` for that vhost | `TD_SERVER_NAME` | derived from `TD_APP_URL` |

The vhost questions appear only if nginx is actually installed on the host. The
stack is perfectly happy fronted from another machine, in which case answer
`no`. `TD_NGINX_ROOT` overrides `/etc/nginx` for testing; when it is set the
installer skips `nginx -t` and the reload, because it is no longer writing to
the configuration the running nginx reads.

!!! warning "The full stack has no default admin password"
    The monolith and Kubernetes modes ship a known default so a local trial
    works immediately. The full stack — the production shape — refuses to
    invent one. Supply a real password, and read
    [Secrets & Encryption](../admin/secrets.md) before the install is reachable
    by anyone else.

### Probe agent (3)

| Prompt | Variable | Default |
|---|---|---|
| Directory of the existing full-stack install | `TD_DIR` | `~/tracedown` |
| Agent slug — its permanent identity, e.g. `eu-1` | `TD_SLUG` | `agent-1` |
| Agent image | `TD_AGENT_IMAGE` | `tracedown/tracedown-probe-agent:latest` |

The slug is permanent and identifies the agent in results and in the UI, so it
is worth naming for where the agent actually is rather than the order you
happened to create it in.

### Kubernetes (4)

| Prompt | Variable | Default |
|---|---|---|
| Directory for the generated manifests | `TD_DIR` | `~/tracedown-k8s` |
| Backend version, or `latest` | `TD_VERSION` | `latest` |
| Namespace | `TD_NAMESPACE` | `tracedown` |
| Ingress host, or `none` to use port-forward | `TD_INGRESS_HOST` | `none` |
| Admin login email | `TD_DEMO_EMAIL` | `admin@tracedown.dev` |
| Admin login password | `TD_DEMO_PASSWORD` | `Down2trace!` |
| The exact context to apply to, or `skip` | `TD_K8S_CONTEXT` | *(none — generate only)* |

This mode needs `kubectl` rather than Docker, and it **never applies to your
ambient context**. You type the target context exactly; it must exist; and it
is passed to `kubectl --context` explicitly. Leave it empty to generate the
manifests and apply them yourself — a reasonable default when the cluster is
not yours to change casually.

## Unattended installs

Because every prompt reads its variable first, setting them all turns the same
script into a non-interactive install:

```bash
TD_MODE=1 \
TD_DIR=/opt/tracedown \
TD_VERSION=latest \
TD_GATEWAY_PORT=20714 \
TD_REALTIME_PORT=20870 \
TD_DEMO_EMAIL=admin@example.com \
TD_DEMO_PASSWORD='<a real password>' \
TD_EMAIL_MODE=none \
  bash -c "$(curl -fsSL https://tracedown.dev/install.sh)"
```

Any prompt you leave unset still needs a terminal. If there is none — a CI
runner, a provisioning step — the installer stops with an error naming the
variable that would have answered it, rather than hanging on a read that will
never return.

Two variables exist only for unattended and testing use:

| Variable | Effect |
|---|---|
| `TD_OVERWRITE` | Pre-answers the "an installation already exists here" prompt. |
| `TD_BASE_URL` | Where mode files are fetched from — point it at a fork or a pinned commit instead of `main`. |

## How it behaves

- **It prompts even when piped.** Under `curl … \| bash` the script itself is
  stdin, so prompts and answers are routed to `/dev/tty`.
- **It refuses to clobber.** Re-running against an existing installation asks
  before overwriting. Re-running is otherwise safe.
- **It loads modes on demand.** Only the entry script is piped; the mode you
  pick is fetched from the same repository and branch the entry came from. Run
  it from a clone and it sources the local files instead. A piped run never
  sources anything from your working directory.
- **Docker is checked only when needed.** Modes 1–3 verify the daemon is up and
  usable by your user, and that Compose v2 is present, before doing anything.
  Mode 4 checks for `kubectl` instead.

## When not to use it

The installer is a convenience over the documented paths, not a replacement for
them. Follow [Production Deploy](deploy.md) directly when you want to place
each piece yourself, when your web server or secrets management does not look
like the shape the installer assumes, or simply when you would rather see every
file before it exists. Nothing the installer does is unavailable by hand.
