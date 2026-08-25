---
description: "Environment-variable reference for every Tracedown service - DATABASE_URL, REDIS_A_URL, PLATFORM_AES_KEY, JWT_SECRET, ports, email, storage and job intervals."
---
# Configuration

Every service reads a HOCON config file baked into its JAR, and every value you
are meant to change is overridable by an environment variable. The pattern is
always the same:

```hocon
database {
    url = "jdbc:postgresql://localhost:5432/tracedown"
    url = ${?DATABASE_URL}
}
```

The second line only takes effect when the variable is set, so the file default
stands unless you override it. This page lists what is actually wired up. If a
setting is not on this page, it is a HOCON value with no environment override,
and changing it means rebuilding — the notable cases are called out in place.

The defaults are tuned for a single-host development stack: Postgres on
`localhost`, an empty password, and secrets that are placeholders. They are not
production values. See [Secrets & Encryption](../admin/secrets.md) for what has
to change before you expose the stack.

## Common to most services

These are read by nearly every JVM service under the same names, which is what
lets the Compose stack define them once and share them across containers.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PORT` | Ktor listen port | Per service — see below | No |
| `DATABASE_URL` | JDBC URL | `jdbc:postgresql://localhost:5432/tracedown` | No — except realtime-service and schema-migrator |
| `DATABASE_USER` | Database user | `tracedown` | Same as above |
| `DATABASE_PASSWORD` | Database password | *(empty)* | Same as above |
| `REDIS_A_URL` | Operational Redis (AOF) — outbox, sessions, queues | `redis://localhost:6379` | No — except realtime-service |
| `REDIS_B_URL` | Ephemeral cache Redis — metrics, rate limits | `redis://localhost:6380` | No |
| `DB_POOL_SIZE` | HikariCP maximum pool size | `10` | No |
| `JAVA_TOOL_OPTIONS` | JVM heap sizing in constrained containers | *(unset)* | No |

Each service has its own default port, so a stock stack has no collisions:

| Service | Default port |
|---|---|
| api-gateway | `20714` |
| probe-scheduler | `20810` |
| result-ingestor | `20820` |
| notification-dispatcher | `20830` |
| email-service | `20840` |
| metrics-service | `20850` |
| aggregate-worker | `20860` |
| realtime-service | `20870` |

Not every service uses every variable. result-ingestor connects to Redis A only.
email-service needs no Postgres at all — it is a pure queue consumer.

!!! warning "`DB_POOL_SIZE` does not apply everywhere"
    `DB_POOL_SIZE` is read directly via `System.getenv`, not through HOCON, and
    it only supplies the *default* pool size. Services that pass an explicit
    pool size in code ignore it entirely: **aggregate-worker**,
    **metrics-service** and **realtime-service** each pin 5 connections. The
    resource-limits overlay sets `DB_POOL_SIZE` for them anyway, which is
    misleading — changing it there has no effect. Only api-gateway,
    probe-scheduler, result-ingestor and notification-dispatcher honour it.

!!! note "Connection budget"
    HikariCP fills to its maximum eagerly and holds the connections idle, so
    pool sizes are a reservation, not a ceiling you might reach. A default stack
    reserves 40 connections across the four services that honour `DB_POOL_SIZE`
    (4 x 10) plus 15 across the three that pin 5 — 55 against a Postgres
    configured for 100. That leaves room, but replicas multiply it: a second
    gateway and scheduler put you at 75. Shrink `DB_POOL_SIZE` before scaling
    out, and see [Scaling](../admin/scaling.md).

### The production guard

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `DEPLOYMENT_ENV` | Deployment environment name; `production` arms the startup guard | `dev` | No — but set it in production |
| `ALLOW_INSECURE_DEV_KEYS` | Disables the guard even in production | *(unset)* | No |

With `DEPLOYMENT_ENV=production`, the api-gateway, probe-scheduler and
email-service refuse to start on published development secrets — the all-zero
`PLATFORM_AES_KEY`, the default `JWT_SECRET`, the seeded demo admin, the
`console` email provider. This is the single most important production setting
on this page: it converts "you forgot to change a secret" from a silent
liability into a startup failure. `ALLOW_INSECURE_DEV_KEYS=true` switches the
guard off; it exists for test rigs.

## api-gateway

The gateway is the only service you expose. It terminates the API, issues
sessions, and owns organisations, workspaces, projects, services, variables,
webhooks, invites and agent registration.

### Connectivity

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PORT` | Listen port | `20714` | No |
| `DATABASE_URL` / `DATABASE_USER` / `DATABASE_PASSWORD` | Postgres connection | See common table | No |
| `REDIS_A_URL` | Operational Redis | `redis://localhost:6379` | No |
| `REDIS_B_URL` | Cache Redis — backs rate limiting | `redis://localhost:6380` | No |
| `REDIS_C_URL` | Resource hierarchy cache | *(empty — disabled)* | No |
| `REDIS_C_TTL_SECONDS` | Hierarchy cache entry TTL | `3600` | No |

Redis C is an optional third role that caches the org → workspace → project →
service hierarchy. Leaving `REDIS_C_URL` empty disables the cache and the
gateway resolves the hierarchy from Postgres — correct, just less cached. Small
deployments should leave it off.

### Security

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `JWT_SECRET` | Reserved token-signing secret — see [Secrets & Encryption](../admin/secrets.md#jwt_secret) | `default-dev-secret-change-in-production` | No — but change it |
| `JWT_TTL_MINUTES` | Session lifetime | `43200` (30 days) | No |
| `PASSWORD_MIN_LENGTH` | Minimum password length | `8` | No |
| `PASSWORD_MIN_UPPERCASE` | Minimum uppercase characters | `1` | No |
| `PASSWORD_MIN_DIGITS` | Minimum digits | `1` | No |
| `PASSWORD_MIN_SPECIAL` | Minimum special characters | `1` | No |
| `TOTP_ISSUER` | Name shown in authenticator apps | `Tracedown` | No |
| `RATE_LIMIT_ENABLED` | Per-IP sliding-window limiting via Redis B | `true` | No |
| `RATE_LIMIT_GENERAL_MAX` | Requests per window, general endpoints | `120` | No |
| `RATE_LIMIT_GENERAL_WINDOW` | General window, seconds | `60` | No |
| `RATE_LIMIT_AUTH_MAX` | Requests per window, auth endpoints | `15` | No |
| `RATE_LIMIT_AUTH_WINDOW` | Auth window, seconds | `60` | No |
| `RATE_LIMIT_TRUSTED_PROXIES` | Trusted proxy hops when deriving the client IP for rate limiting | `1` | No |

The password minimums compose rather than replace: the length floor is `8` *and*
within it at least one uppercase, one digit and one special character must
appear. Auth endpoints get a tighter budget than general traffic because they
are the ones worth brute-forcing.

`RATE_LIMIT_TRUSTED_PROXIES` is how the gateway decides which
`X-Forwarded-For` hop is the real client. The default of `1` matches the
single host web server the [deploy stack](deploy.md) expects in front of the
gateway; set it to your actual proxy depth, because a wrong
value makes rate limiting either spoofable or keyed to your proxy's address.

!!! note "Sessions are not JWTs"
    Despite the name, `JWT_SECRET` does not sign session tokens — sessions are
    opaque random tokens stored hashed in the database, and rotating this value
    does **not** log anyone out. It is guarded against its dev default in
    production and reserved for future signing use. See
    [Secrets & Encryption](../admin/secrets.md#jwt_secret).

### Platform

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `APP_URL` | Frontend base URL used in emails | `http://localhost:5173` | No |
| `URI_INVITE` | Frontend invite route, appended to `APP_URL` | `/invite` | No |
| `URI_PASSWORD_RESET` | Frontend reset route | `/reset-password` | No |
| `PLATFORM_AES_KEY` | 64 hex chars — encrypts secrets, signs challenges | 64 zeros | No — but change it |
| `SINGLE_ORG_MODE` | Bootstrap a default org and user on first start | `true` | No |
| `DEMO_USER_EMAIL` | Bootstrap user email | `admin@tracedown.dev` | No |
| `DEMO_USER_PASSWORD` | Bootstrap user password | `Down2trace!` | No |
| `INVITE_TTL_DAYS` | Invite token lifetime | `7` | No |
| `INVITE_RESEND_COOLDOWN_MINUTES` | Minimum gap between invite resends | `5` | No |
| `TRUSTED_DOMAIN_MODE` | Skip domain-ownership checks (auto-verify all) | `false` | No |
| `ALLOW_PROFILE_EDIT` | Let users edit their display name | `true` | No |
| `METRICS_PUBLIC_URL` | Public metrics base URL shown in Grafana integrations | *(empty)* | No |
| `AUDIT_LOG_RETENTION_DAYS` | Days to keep audit log entries (enforced by the aggregate-worker; set identically in both) | `90` | No |

`APP_URL` is what users click. It is the base for invite and reset links in
outgoing email, so it must be the URL a browser can reach — not an internal
container hostname — or your invites will land as dead links.

!!! warning "The demo credentials are published defaults"
    With `SINGLE_ORG_MODE=true` the gateway creates an org and a user with the
    values above on first start. They are documented, and therefore public.
    Override both before first boot, or log in and change the password
    immediately after. The bootstrap only fires when the database is empty, so
    changing them later does not retroactively fix an account already created.

#### Domain trust

`TRUSTED_DOMAIN_MODE` is the single switch that decides whether Tracedown cares
who owns the target of a probe. It defaults to `false` — verified mode — as a
signal of good-faith use of the platform. Domains must be
verified before they are probed freely, and probes against unverified domains
are constrained to:

- a maximum of **3 calls per script**,
- **no body saving**,
- a minimum **5-minute interval**,
- **no `includes()`** — it would otherwise let a script scrape third-party
  response content.

Verified mode also reveals the Domains UI and enables the worker's
`DomainReverifyJob`. The point is to stop the platform being pointed at
infrastructure you do not control.

Set `TRUSTED_DOMAIN_MODE=true` to skip ownership checks and auto-verify every
domain — convenient for a self-hosted install probing only infrastructure you
own, at the cost of those protections. Set the same value on api-gateway,
probe-scheduler and aggregate-worker — each reads it independently, and a split
setting produces a stack that enforces the limits in one place and not another.

#### Automatic DNS setup

A user proving ownership has to put a TXT record in their zone. In the domains
UI they can paste an API token for a supported DNS provider (Cloudflare today)
and have the gateway write the record for them. The token is used for that one
request — the zone lookup and the write — and is never stored, logged, or
reused. There is nothing to configure: the option appears wherever the provider
is reachable, and the record can always be added by hand instead.

The gateway also recognises the domain's DNS provider from its name-server
delegation (`DnsProviderProfiles` — Cloudflare, Route 53, GoDaddy, Namecheap and
a dozen more), walking up from `api.example.com` to the zone actually delegated.
That costs one DNS lookup and needs no credential, so it works for providers we
have no API client for: it names the provider and, where one exists, the page
that edits that zone's records.

Where a recognised provider has an addressable DNS page, the domains UI offers
an "Open DNS in <provider>" button that goes straight to it — the record is
still pasted by hand, and no credential is involved.

A host application can replace that with something richer through the
frontend's `domain-dns-setup` slot; when it does, the built-in button stands
down rather than offering the same thing twice.

#### Retention

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PURGE_RETENTION_DAYS` | Days after soft-delete before hard purge | `0` (immediate) | No |
| `RESULT_RETENTION_DAYS` | Probe-result retention — caps the usage window | `90` | No |

!!! warning "`RESULT_RETENTION_DAYS` is set in two places"
    The gateway uses it to bound the usage window; aggregate-worker uses it to
    decide what to actually delete. They are separate variables in separate
    services with the same name. If the gateway's value exceeds the worker's,
    the UI offers a window whose data has already been deleted. Keep them
    identical. See [Retention & Aggregation](../admin/retention.md).

#### Variables

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `MAX_VARS_PER_RESOURCE` | Most variables one resource may hold | `100` | No |

Counted **separately per resource** — per organization, workspace, project,
service and webhook — so a project at the cap does not stop its services having
their own. Variables are read on every probe dispatch, so an unbounded set costs
both storage and hot-path time; the cap bounds runaway or automated creation,
and is the same number for every organization.

System-managed variables are not counted against it: the defaults seeded at
organization creation, and the companion variables a config toggle creates.
Enabling a feature never fails for want of room.

Deleting a variable frees its slot — the count is of live variables, not of
everything ever created. A create beyond the cap is refused with
`variable_limit_reached`.

#### Probe request limits

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `REQUEST_TIMEOUT_MS` | Outbound probe request timeout | `30000` | No |
| `MAX_RETRIES` | Maximum retries | `10` | No |
| `MAX_REDIRECTS` | Maximum redirect hops | `10` | No |

#### Seed data

Seeding only runs as part of the `SINGLE_ORG_MODE` bootstrap, so it is a
first-boot-only affair.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `SEED_ENABLED` | Seed demo data during bootstrap | `false` | No |
| `SEED_PROJECT_NAME` | Seeded project name | `Default` | No |
| `SEED_SERVICE_NAME` | Seeded service name | `httpbin` | No |
| `SEED_TARGET_URL` | Seeded probe target | `https://httpbin.org/get` | No |
| `SEED_SCHEDULE` | Seeded probe cron | `*/5 * * * *` | No |

??? note "Default groups are not configurable by environment"
    Each new organisation gets four groups — Admins, Users, Viewers and DevOps —
    with per-section access levels (`0` none, `1` read, `2` write). This is a
    HOCON list with no environment override; changing the defaults means editing
    `platform.conf` and rebuilding. Group membership and permissions are
    editable per-org in the UI afterwards, which is the intended path.

### Email

The gateway sends transactional mail directly — invites and password resets.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `EMAIL_PROVIDER` | One of `smtp`, `resend`, `mailgun`, `console`, `file` | `console` | No |
| `EMAIL_FROM_ADDRESS` | Envelope from address | `noreply@tracedown.dev` | No |
| `EMAIL_FROM_NAME` | Display name | `Tracedown` | No |
| `EMAIL_FILE_PATH` | Output path for the `file` provider | `build/email-output.eml` | No |
| `SMTP_HOST` | SMTP host | `localhost` | Yes, for `smtp` |
| `SMTP_PORT` | SMTP port | `587` | No |
| `SMTP_USERNAME` | SMTP username | *(empty)* | No |
| `SMTP_PASSWORD` | SMTP password | *(empty)* | No |
| `SMTP_TLS_MODE` | One of `STARTTLS`, `SMTPS`, `PLAIN` | `STARTTLS` | No |
| `RESEND_API_KEY` | Resend API key | *(empty)* | Yes, for `resend` |
| `MAILGUN_API_KEY` | Mailgun API key | *(empty)* | Yes, for `mailgun` |
| `MAILGUN_DOMAIN` | Mailgun sending domain | *(empty)* | Yes, for `mailgun` |
| `MAILGUN_REGION` | `us` or `eu` | `us` | No |
| `EMAIL_CONSOLE_ATTACHMENT_DIR` | Where the `console` provider writes attachments | `build/email-attachments` | No |

The default `console` provider prints mail to the log instead of sending it.
That is fine until you invite someone — with `console` the invite link only
exists in the gateway's log. The `file` provider writes only the **latest**
email to the path, overwriting each time; it exists for tests.

!!! warning "The gateway and email-service use different variable names"
    Both services send mail, and they do **not** share provider settings. The
    gateway reads `SMTP_*`, `RESEND_API_KEY` and `MAILGUN_*`; the email-service
    reads `EMAIL_SMTP_*`, `EMAIL_RESEND_API_KEY` and `EMAIL_MAILGUN_*`. Setting
    only one pair configures only one sender, and the other silently falls back
    to `console` — mail vanishes into a log rather than erroring. If both send,
    configure both.

    The four names they *do* share — `EMAIL_PROVIDER`, `EMAIL_FROM_ADDRESS`,
    `EMAIL_FROM_NAME` and `EMAIL_FILE_PATH` — are read by both services, so a
    single value set in Compose applies to both at once. That is usually what
    you want; just be aware it is not scoped — and that two of the four
    (`EMAIL_FROM_ADDRESS` and `EMAIL_FILE_PATH`) carry **different defaults**
    in each service when you set nothing.

## probe-scheduler

The scheduler owns cron evaluation and dispatch to agents. It talks to Postgres,
Redis A, and the agents over mutual TLS.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PORT` | Listen port | `20810` | No |
| `PLATFORM_AES_KEY` | Decrypts variables and the CA key for its client cert | 64 zeros | No — but change it |
| `GATEWAY_URL` | Gateway base URL, for health-challenge tokens | `http://localhost:8080` | No |
| `SCHEDULER_SWEEP_INTERVAL` | Consistency sweep interval, seconds | `300` | No |
| `SCHEDULER_THREAD_POOL_SIZE` | Quartz thread pool size | `10` | No |
| `SCHEDULER_DISPATCH_QUEUE_SIZE` | Dispatch queue depth | `100000` | No |
| `SCHEDULER_DISPATCH_WORKERS` | Concurrent in-flight dispatches | `50` | No |
| `TRUSTED_DOMAIN_MODE` | Skip domain-ownership checks (auto-verify all) | `false` | No |
| `PROBE_DEFAULT_TIMEOUT_MS` | Per-request timeout when a service has no override | `30000` | No |
| `PROBE_MAX_TIMEOUT_MS` | System-wide maximum timeout | `300000` | No |
| `PROBE_MAX_REDIRECTS` | Maximum redirect hops | `10` | No |
| `PROBE_PAYLOAD_ENCRYPTION_ENABLED` | Fleet-wide kill switch for per-agent payload sealing | `true` | No |

`PROBE_MAX_TIMEOUT_MS` is a clamp, not a default — per-service overrides are
capped at it, so it is the real ceiling on how long one probe can occupy a
dispatch worker.

`PROBE_PAYLOAD_ENCRYPTION_ENABLED` turns nothing on. Whether a dispatch is
sealed to the agent's certificate on top of mutual TLS is a **per-agent**
setting — see [Probe Agents](agents.md#encrypting-the-payload-in-flight). This
variable exists only so the mechanism can be disabled fleet-wide from the
environment, without editing rows; set it `false` and every dispatch travels as
it did before, inside mutual TLS and nothing more.

The `GATEWAY_URL` default points at `localhost:8080`, which is **not** the
gateway's own default port. Set it explicitly; in Compose it is the internal
service URL.

The dispatch queue holds service IDs (~50 bytes each), so `100000` is cheap. It
needs to exceed your largest per-tick fleet: when it fills, the overflow is shed
as `skipped` runs even if the agents were idle.

!!! warning "Raising `SCHEDULER_DISPATCH_WORKERS` is rarely the fix"
    Each worker blocks on an agent's probe round-trip, so this value is global
    backpressure — it caps how many connections the platform opens against
    targets at once. It is `50` deliberately. Raising it lets the scheduler
    overwhelm a slow target; congestion collapse and runaway latency have been
    observed against a single internet-hosted endpoint. If you need more
    throughput, add agents — see [Probe Agents](agents.md). Raise this only when
    you know the targets absorb the extra concurrency.

## result-ingestor

Consumes probe results from Redis A and persists them. Postgres and Redis A —
no Redis B — plus the body-storage settings below.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PORT` | Listen port | `20820` | No |
| `DATABASE_URL` / `DATABASE_USER` / `DATABASE_PASSWORD` | Postgres connection | See common table | No |
| `REDIS_A_URL` | Queue to consume from | `redis://localhost:6379` | No |
| `STORAGE_FILESYSTEM_ROOT` | Root under which agent-written bodies are relocated — must match the agent's `PROBE_AGENT_STORAGE_DIR` | `/data/bodies` | No |
| `STORAGE_S3_ENDPOINT` | S3-compatible endpoint — presence enables S3 body relocation | *(unset)* | No |
| `STORAGE_S3_ACCESS_KEY` / `STORAGE_S3_SECRET_KEY` | S3 credentials | *(empty)* | Yes, once the endpoint is set |
| `STORAGE_S3_BUCKET` | Bucket for relocated bodies | *(unset)* | Yes, once the endpoint is set |
| `STORAGE_S3_PREFIX` | Key prefix within the bucket | *(empty)* | No |

The storage settings mirror where the agents put saved response bodies: the
ingestor relocates bodies as results land, so its view of the store has to
match the agents' — same filesystem root when bodies are on a shared volume,
same S3 endpoint when they are in a bucket.

!!! note "Queue pop timeout is fixed"
    The ingestor's blocking-pop timeout (5 seconds) is a code default with no
    HOCON entry and no environment override. It is not tunable without a
    rebuild, and there is little reason to want it to be.

## notification-dispatcher

Consumes outbox events and delivers email and webhook notifications.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PORT` | Listen port | `20830` | No |
| `DATABASE_URL` / `DATABASE_USER` / `DATABASE_PASSWORD` | Postgres connection | See common table | No |
| `REDIS_A_URL` | Operational Redis | `redis://localhost:6379` | No |
| `PLATFORM_AES_KEY` | Decrypts org variables referenced from webhook URLs | 64 zeros | No — but change it |
| `DISPATCHER_POLL_INTERVAL_MS` | Outbox poll interval | `5000` | No |
| `DISPATCHER_BATCH_SIZE` | Events per batch | `50` | No |
| `DISPATCHER_STATUS_POP_TIMEOUT` | Status queue pop timeout, seconds | `5` | No |

!!! danger "`PLATFORM_AES_KEY` must match the gateway's"
    Webhook URLs can reference org variables (for example `$o.telegramToken`),
    which the gateway encrypted with its key. The dispatcher decrypts them with
    its own. If the two differ, decryption fails and those webhooks never
    deliver. The same applies to the scheduler, which decrypts probe variables.
    One key, every service. See [Secrets & Encryption](../admin/secrets.md).

??? note "Webhook retry behaviour is not configurable by environment"
    Retry backoff (base 2 seconds, growing 4x) and the per-recipient cooldown
    (`300` seconds) are code defaults with no `application.conf` entries. The
    attempt ceiling itself is **per webhook** rather than configuration: each
    webhook carries an attempt count (1–10, default 1 — no retry), set when the
    webhook is created or edited.

## email-service

A queue-based email dispatcher. It consumes from Redis and sends — it needs
**no Postgres connection at all**.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PORT` | Listen port | `20840` | No |
| `REDIS_A_URL` | Queue to consume from | `redis://localhost:6379` | No |
| `EMAIL_PROVIDER` | One of `smtp`, `resend`, `mailgun`, `console`, `file` | `console` | No |
| `EMAIL_FROM_ADDRESS` | Envelope from address | `notifications@tracedown.dev` | No |
| `EMAIL_FROM_NAME` | Display name | `Tracedown` | No |
| `EMAIL_SMTP_HOST` | SMTP host | *(empty)* | Yes, for `smtp` |
| `EMAIL_SMTP_PORT` | SMTP port | `587` | No |
| `EMAIL_SMTP_USERNAME` | SMTP username | *(empty)* | No |
| `EMAIL_SMTP_PASSWORD` | SMTP password | *(empty)* | No |
| `EMAIL_SMTP_TLS_MODE` | One of `STARTTLS`, `SMTPS`, `PLAIN` | `STARTTLS` | No |
| `EMAIL_RESEND_API_KEY` | Resend API key | *(empty)* | Yes, for `resend` |
| `EMAIL_MAILGUN_API_KEY` | Mailgun API key | *(empty)* | Yes, for `mailgun` |
| `EMAIL_MAILGUN_DOMAIN` | Mailgun sending domain | *(empty)* | Yes, for `mailgun` |
| `EMAIL_MAILGUN_REGION` | `us` or `eu` | `us` | No |
| `EMAIL_FILE_PATH` | Output path for the `file` provider — a single file, overwritten each send | `./emails` | No |
| `EMAIL_CONSOLE_ATTACHMENT_DIR` | Where the `console` provider writes attachments | `build/email-attachments` | No |
| `EMAIL_SERVICE_POP_TIMEOUT` | Queue pop timeout, seconds | `5` | No |

Note the defaults differ from the gateway's for the same concepts:
`EMAIL_FROM_ADDRESS` defaults to a different address, `EMAIL_SMTP_HOST` is
empty rather than `localhost`, and `EMAIL_FILE_PATH` defaults to a different
path (still a single overwritten file — its default yields a file literally
named `emails`). Re-read the naming warning under [Email](#email) before
assuming a value you set applies here.

## metrics-service

Exposes the Prometheus scrape endpoint and backs Grafana integration.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PORT` | Listen port | `20850` | No |
| `DATABASE_URL` / `DATABASE_USER` / `DATABASE_PASSWORD` | Postgres connection | See common table | No |
| `REDIS_A_URL` | Operational Redis | `redis://localhost:6379` | No |
| `REDIS_B_URL` | Cache Redis — holds the metric buckets | `redis://localhost:6380` | No |
| `METRICS_TTL_SECONDS` | Metric entry TTL | `86400` (1 day) | No |
| `METRICS_HOURLY_BUCKET_TTL_SECONDS` | Hourly bucket TTL | `90000` (25 hours) | No |

The hourly bucket TTL exceeds the metric TTL by an hour on purpose: a bucket
must outlive the window it summarises, or the final scrape of an hour reads an
expired key.

This service pins a pool of 5 connections and ignores `DB_POOL_SIZE`.

!!! note "The usage bucket TTL is fixed"
    `metrics.usageBucketTtlSeconds` (604800 — 7 days) has no HOCON entry and so
    no environment override.

## aggregate-worker

Rolls raw results into hourly and daily aggregates, enforces retention, purges
soft-deleted rows, and cleans up sessions. What each job does is covered in
[Retention & Aggregation](../admin/retention.md); this is the configuration
surface.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PORT` | Listen port | `20860` | No |
| `DATABASE_URL` / `DATABASE_USER` / `DATABASE_PASSWORD` | Postgres connection | See common table | No |
| `REDIS_A_URL` | Operational Redis | `redis://localhost:6379` | No |
| `REDIS_B_URL` | Cache Redis | `redis://localhost:6380` | No |
| `RESULT_RETENTION_DAYS` | Raw probe result retention; `-1` keeps forever | `90` | No |
| `HOURLY_AGGREGATE_RETENTION_DAYS` | Hourly aggregate retention; `-1` keeps forever | `365` | No |
| `AGENT_HEALTH_RETENTION_DAYS` | Agent health record retention; `-1` keeps forever | `90` | No |
| `AUDIT_LOG_RETENTION_DAYS` | Audit log retention; `-1` keeps forever | `90` | No |
| `NOTIFICATION_LOG_RETENTION_DAYS` | Notification delivery history retention; `-1` keeps forever | `90` | No |
| `TRUSTED_DOMAIN_MODE` | When `true`, `DomainReverifyJob` is disabled | `false` | No |

Raw results are the bulk of the database and hourly aggregates are cheap, which
is why they default to 90 and 365 days respectively — you keep a year of trend
after the detail ages out. Setting `RESULT_RETENTION_DAYS=-1` disables deletion
entirely and the table grows without bound; if you do, plan disk accordingly.

Keep `RESULT_RETENTION_DAYS` identical to the gateway's value.

### Job intervals

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `WORKER_INTERVAL_HOURLY_AGGREGATION` | Hourly aggregation interval, seconds | `900` | No |
| `WORKER_INTERVAL_DAILY_AGGREGATION` | Daily aggregation interval, seconds | `3600` | No |
| `WORKER_INTERVAL_RETENTION` | Retention interval, seconds | `3600` | No |
| `WORKER_INTERVAL_PURGE` | Three-tier deletion purge interval, seconds | `300` | No |
| `WORKER_INTERVAL_SESSION_CLEANUP` | Expired session cleanup interval, seconds | `900` | No |

`WORKER_INTERVAL_RETENTION` drives more than retention: the outbox purge, agent
health cleanup, audit-log and notification-log trims and expired-token cleanup
all run on the same tick.

### Body storage

At retention time the worker deletes saved response bodies from S3-compatible
storage alongside the database rows.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `STORAGE_S3_ENDPOINT` | S3-compatible endpoint — presence enables deletion | *(unset)* | No |
| `STORAGE_S3_ACCESS_KEY` | Access key | *(empty)* | Yes, once the endpoint is set |
| `STORAGE_S3_SECRET_KEY` | Secret key | *(empty)* | Yes, once the endpoint is set |

!!! warning "The endpoint variable is the on/off switch"
    `STORAGE_S3_ENDPOINT` has no default. Its **presence** enables S3 body
    deletion; leaving it unset disables it. Setting it to an empty string is not
    the same as leaving it out. If bodies are stored in S3 and the endpoint is
    unset here, retention deletes the database rows and the objects are orphaned
    — they accrue cost forever with nothing referencing them.

Any S3-compatible store works: Cloudflare R2, MinIO, Backblaze B2, Spaces.

This service pins a pool of 5 connections and ignores `DB_POOL_SIZE`.

## realtime-service

A WebSocket server that bridges Redis pub/sub to connected browsers.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `PORT` | Listen port | `20870` | No |
| `DATABASE_URL` | JDBC URL | *(none)* | **Yes** |
| `DATABASE_USER` | Database user | *(none)* | **Yes** |
| `DATABASE_PASSWORD` | Database password | *(none)* | **Yes** |
| `REDIS_A_URL` | Redis to subscribe to | *(none)* | **Yes** |

!!! warning "realtime-service has no fallback defaults"
    Alone among the services, its `application.conf` uses mandatory HOCON
    substitutions — `${DATABASE_URL}`, not `${?DATABASE_URL}`. There are no
    baked-in defaults, so an unset variable is a startup failure, not a silent
    fallback to `localhost`. All four must be set. This is why it is the service
    that most often fails to boot when you run it outside Compose.

    Note `DATABASE_PASSWORD` must be *set*, but may be empty — an empty value
    satisfies the substitution.

This service pins a pool of 5 connections and ignores `DB_POOL_SIZE`.

??? note "Ping intervals are fixed"
    `realtime.pingIntervalMs` (5000) and `realtime.pingTimeoutMs` (10000) have
    no environment overrides. Clients that need different keepalive timing
    cannot get it by configuration.

## Compose environment

The Docker stack reads `docker/.env`, which you create by copying the shipped
`docker/.env.example`. It is the one file most installs need to edit, and every
value the template ships is a development default.

| Variable | Purpose | Default | Required |
|---|---|---|---|
| `DB_NAME` | Database name | `tracedown` | No |
| `DB_USER` | Database user | `tracedown` | No |
| `DB_PASSWORD` | Database password | `tracedown` | No |
| `PLATFORM_AES_KEY` | Shared 64-hex-char encryption key | Dev placeholder | No — but change it |
| `JWT_SECRET` | Session signing secret | Dev placeholder | No — but change it |
| `GATEWAY_PORT` | Host (127.0.0.1) port for the API gateway | `20714` | No |
| `REALTIME_PORT` | Host (127.0.0.1) port for the WebSocket | `20870` | No |
| `METRICS_PORT` | Host (127.0.0.1) port for the metrics endpoint | `20850` | No |
| `REDIS_A_URL` | Operational Redis URL | Container-internal | No |
| `REDIS_B_URL` | Cache Redis URL | Container-internal | No |
| `REDIS_C_URL` | Hierarchy cache Redis URL | Container-internal | No |

!!! danger "Every shipped value is a development default"
    The password is the username, and the AES key and JWT secret are
    placeholders committed to the repository. They exist so `docker compose up`
    works with no setup — see [Quickstart](quickstart.md). All of them must
    change before the stack is reachable by anyone but you.
    [Secrets & Encryption](../admin/secrets.md) covers generating real values
    and the consequences of rotating each one.

The dev stack points all three Redis URLs at a **single** Redis container
serving every role. That is fine for one host and wrong under load: Redis A is
AOF-persisted operational state, Redis B is a throwaway cache, and mixing them
means cache churn competes with the outbox. The Compose file ships commented-out
`redis-b` and `redis-c` services; uncomment them and repoint the URLs when you
scale out. See [Scaling](../admin/scaling.md).

## Probe agents

Probe agents are configured separately. They are a Python service using
pydantic-settings, and every variable is prefixed `PROBE_AGENT_`. Agents hold
their own keypair and are dialled *by* the scheduler over mutual TLS, so their
configuration is mostly about identity and reachability rather than the shared
database and Redis above.

See [Probe Agents](agents.md) for the full reference.
