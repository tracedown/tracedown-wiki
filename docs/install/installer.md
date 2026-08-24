---
description: "Reference for the interactive Tracedown installer: the four modes, every prompt and default, and the TD_* variables that pre-answer them for unattended installs."
---
# The interactive installer

```bash
curl -fsSL https://tracedown.dev/install.sh | bash
```

`https://tracedown.dev/install.sh` redirects to `install.sh` on `main` in
[tracedown-install](https://github.com/tracedown/tracedown-install).

## Prerequisites

| | |
|---|---|
| Always | `curl`, `openssl` |
| Modes 1–3 | Docker, with the Compose plugin (`docker compose`, not `docker-compose`) |
| Mode 4 | `kubectl` |

Modes 1–3 verify that the Docker daemon is running and usable by the current
user before doing anything.

## Modes

| # | Mode | Result |
|---|---|---|
| 1 | Monolith | [The single jar](monolith.md) in one container, plus PostgreSQL and Redis. |
| 2 | Full stack | [The per-service deployment](deploy.md) — 11 containers from published release artifacts. Optionally writes and enables the host nginx vhost. |
| 3 | Probe agent | Mints a bootstrap token on an existing full stack and connects [an agent](agents.md). |
| 4 | Kubernetes | Generates plain manifests for the monolith and applies them to a named context. |

Mode 3 requires an existing full-stack installation. Modes 1, 2 and 4 do not.

## Prompts

Every prompt is skipped when its variable is already set. Defaults are shown in
brackets at the prompt; enter accepts them.

### All modes

| Prompt | Variable | Default |
|---|---|---|
| Mode | `TD_MODE` | `1` |
| Email delivery: `smtp` or `none` | `TD_EMAIL_MODE` | `none` |
| SMTP host | `TD_SMTP_HOST` | — |
| SMTP port | `TD_SMTP_PORT` | `587` |
| SMTP username | `TD_SMTP_USERNAME` | — |
| SMTP password | `TD_SMTP_PASSWORD` | — |
| From address | `TD_EMAIL_FROM` | `notifications@` + the SMTP host, less any leading `smtp.` |

The SMTP prompts appear only when `TD_EMAIL_MODE=smtp`. Under `none`, mail is
written to the logs and nothing is sent.

### 1 — Monolith

| Prompt | Variable | Default |
|---|---|---|
| Install directory | `TD_DIR` | `~/tracedown` |
| Backend version, or `latest` | `TD_VERSION` | `latest` |
| Gateway port (dashboard + API) | `TD_GATEWAY_PORT` | `20714` |
| WebSocket port | `TD_REALTIME_PORT` | `20870` |
| Admin login email | `TD_DEMO_EMAIL` | `admin@tracedown.dev` |
| Admin login password | `TD_DEMO_PASSWORD` | `Down2trace!` |

### 2 — Full stack

| Prompt | Variable | Default |
|---|---|---|
| Install directory | `TD_DIR` | `~/tracedown` |
| Backend version, or `latest` | `TD_VERSION` | `latest` |
| Public base URL | `TD_APP_URL` | `https://tracedown.example.com` |
| Admin login email | `TD_DEMO_EMAIL` | `admin@tracedown.dev` |
| Admin login password | `TD_DEMO_PASSWORD` | none — must be supplied |
| Write and enable the nginx vhost | `TD_HOST_CONF` | `yes` |
| `server_name` for the vhost | `TD_SERVER_NAME` | derived from `TD_APP_URL` |

The vhost prompts appear only when nginx is installed on the host. `TD_NGINX_ROOT`
overrides `/etc/nginx`; when it is set, `nginx -t` and the reload are skipped.

!!! warning "No default admin password in this mode"
    Modes 1 and 4 ship a known default password for local trials. Mode 2 does
    not and will not proceed without one. See
    [Secrets & Encryption](../admin/secrets.md) before the install is reachable
    by others.

### 3 — Probe agent

| Prompt | Variable | Default |
|---|---|---|
| Directory of the existing full-stack install | `TD_DIR` | `~/tracedown` |
| Agent slug — permanent identity, e.g. `eu-1` | `TD_SLUG` | `agent-1` |
| Agent image | `TD_AGENT_IMAGE` | `tracedown/tracedown-probe-agent:latest` |

The slug is permanent and identifies the agent in results and in the UI.

### 4 — Kubernetes

| Prompt | Variable | Default |
|---|---|---|
| Directory for generated manifests | `TD_DIR` | `~/tracedown-k8s` |
| Backend version, or `latest` | `TD_VERSION` | `latest` |
| Namespace | `TD_NAMESPACE` | `tracedown` |
| Ingress host, or `none` for port-forward | `TD_INGRESS_HOST` | `none` |
| Admin login email | `TD_DEMO_EMAIL` | `admin@tracedown.dev` |
| Admin login password | `TD_DEMO_PASSWORD` | `Down2trace!` |
| Context to apply to, or `skip` | `TD_K8S_CONTEXT` | none — generate only |

The ambient kubectl context is never used. `TD_K8S_CONTEXT` must name an
existing context exactly and is passed as `kubectl --context`. Left empty, the
manifests are generated and not applied.

## Unattended installs

Setting every prompt's variable makes the run non-interactive:

```bash
TD_MODE=1 \
TD_DIR=/opt/tracedown \
TD_VERSION=latest \
TD_GATEWAY_PORT=20714 \
TD_REALTIME_PORT=20870 \
TD_DEMO_EMAIL=admin@example.com \
TD_DEMO_PASSWORD='<password>' \
TD_EMAIL_MODE=none \
  bash -c "$(curl -fsSL https://tracedown.dev/install.sh)"
```

An unset prompt still requires a terminal. Without one, the installer exits
with an error naming the variable that would have answered it.

Two further variables have no prompt:

| Variable | Effect |
|---|---|
| `TD_OVERWRITE` | Pre-answers the "installation already exists" prompt. |
| `TD_BASE_URL` | Source for the mode files. Defaults to `main` in `tracedown-install`; set it to pin a commit or use a fork. |

## Behaviour

- Prompts are read from `/dev/tty`, so they work under `curl … | bash`, where
  the script itself occupies stdin.
- An existing installation is not overwritten without confirmation. Re-running
  is otherwise safe.
- Only the entry script is piped. The selected mode is fetched from the same
  repository and branch the entry came from, or sourced from the local files
  when run from a clone. A piped run never sources from the working directory.
- Everything is written under `TD_DIR`. Nothing outside it is modified except
  Docker resources and, on confirmation in mode 2, the nginx vhost.

## Doing it by hand

The installer covers the documented paths and adds nothing that is unavailable
manually. Follow [Production Deploy](deploy.md) to place each component
yourself.
