---
description: "The Tracedown API for scripts, pipelines and agents: API keys, authentication, errors, the per-key rate budget, paging, run handles, step bodies, idempotent requests, the event feed, the OpenAPI description, and a complete worked example."
---
# The API

!!! note "Tracedown 0.4.50 and later"
    This page describes the API as served from release 0.4.60 on. Release 0.4.49
    serves only `GET /key` under `/api/public/v1`; 0.4.50 adds the resource
    endpoints. **0.4.59** adds the run handle (`runId` and
    `GET /services/{id}/runs/{runId}`), the result filters, the raw body
    download, script validation, `Idempotency-Key` and agent health.
    **0.4.60** adds script presets, notification templates, the warning log
    (`/alerts`) and the event feed (`/events`). Against an older gateway, those
    routes answer 404 and the new fields are absent.

Everything you do to a service in the dashboard — create it, give it a script,
switch it on, run it, read what came back — a script can do too, through the
key-authenticated API at `/api/public/v1`. It is built for direct callers: a CI
job that deploys a service with the code it monitors, a pipeline that runs a
probe after a release and fails the build on the result, an agent working
through a toolkit generated from the [API description](#the-api-description).

It is not the dashboard's API. The dashboard talks to `/api/v1`, which changes
whenever the screens do and is not something to build on. `/api/public/v1` is a
contract with its own version line, and it accepts an API key and nothing else.

This page covers keys, calling conventions, errors, the rate budget and paging,
[running a service and waiting for it](#running-a-service-now),
[idempotent requests](#idempotency) and the [event feed](#event-feed), and ends
with a [worked example](#a-complete-example). Every endpoint is listed
in the [API Reference](api-reference.md).

## API keys

A key is a credential that **acts as the member who created it, in one
organization**. It holds no permissions of its own: each request it makes is
checked against what that member may do at that moment, by the same checks the
dashboard applies to their session. So:

- a key can **never do more than its member** can. A resource the member cannot
  see is one the key cannot see; demote the member and the key is demoted on its
  next request;
- a key works in **one organization**, the one it was created in. A key that
  leaks exposes that organization and no other;
- a key carries an **access level** on top: **read** keys may only send `GET`
  and `HEAD` requests — and `POST /scripts/validate`, which changes nothing —
  and **write** keys may do whatever their member may;
- a key can have an **expiry**, from 1 to 3650 days, or none;
- a key **stops working** as soon as its member cannot act in the organization
  — their membership or account disabled, or the account gone — and while the
  organization, or a group the member belongs to, requires two-factor
  authentication that the member has not enrolled in. Removing a member from
  the organization revokes their keys there.

Each member may hold a limited number of keys across all their organizations —
see [the key limit](account.md#creating-a-key).

### Getting a key

Keys are created in the dashboard, under **My account → API keys → New API
key**, by the member they will act as; nobody can create a key that acts as
somebody else. You choose a name, the access level and the expiry, and confirm
with your password — plus a two-factor code if you have two-factor enabled. The
key acts in the organization you are signed in to.

The key is shown **once**, in the dialog that created it, together with the base
URL to call. Tracedown keeps only a SHA-256 digest of it, so it cannot be shown
again. Store it the way you store any other secret: in your CI system's secret
store, a vault, a password manager.

[Your Account](account.md#api-keys) walks through the form, the key states and
what a key survives;
[API key oversight](users-and-permissions.md#api-key-oversight) covers who else
can see and revoke your keys.

A key has the form `td_` followed by 43 characters of base64url — 46 characters
in all. The first eleven (`td_` plus eight) are its **prefix**, which the lists
in the dashboard show so you can tell keys apart and find one that leaked.

!!! tip "Use a read key wherever you can"
    A pipeline that only reads results, a dashboard that only shows metrics, an
    agent that only answers questions — give them a **read** key. If it leaks,
    nothing can be changed with it.

## Calling the API

| | |
|---|---|
| Base URL | `https://<your Tracedown host>/api/public/v1` |
| Authentication | `Authorization: Bearer td_…` on every request |
| Bodies | JSON in, JSON out — except the [raw body download](#step-bodies), which answers the stored bytes. A request with a body must send `Content-Type: application/json`. |
| Retries | Every `POST` but `/scripts/validate` takes an [`Idempotency-Key`](#idempotency), which makes sending it twice safe. |
| Description | `GET /api/openapi/public/v1.json`, no key needed |

The base URL is the address you open the dashboard at, followed by
`/api/public/v1` — the base URL the key's dialog shows. The examples on this
page set two shell variables:

```bash
export TRACEDOWN=https://tracedown.example.com
export TRACEDOWN_KEY=td_...   # from My account → API keys
```

The key goes in the `Authorization` header and nowhere else — there is no
query-parameter form and no `X-Api-Key` header. A page in a browser on another
origin can call the API only if the operator lists that origin in
[`API_CORS_ORIGINS`](../install/configuration.md#cross-origin-access-api_cors_origins).
A key in browser code is readable by everyone who loads the page. Start by
asking the API who the key is:

```bash
curl -s "$TRACEDOWN/api/public/v1/key" \
  -H "Authorization: Bearer $TRACEDOWN_KEY"
```

```json
{
  "id": "2f9c1e7a-…",
  "name": "ci-deploy",
  "prefix": "td_8Qm3xYpL",
  "access": "write",
  "expiresAt": "2027-01-01T09:30:00Z",
  "organization": { "id": "5b0d…", "name": "Acme" },
  "user": { "id": "a41e…", "email": "dev@acme.example" }
}
```

That call is the cheapest way for a client to check its key before relying on
it.

Two things the namespace enforces that are worth knowing:

- **The path decides which credential is accepted.** Under `/api/public` only an
  API key is; a dashboard session token sent there is refused with
  `invalid_api_key`. Everywhere else only a session is; an API key sent to
  `/api/v1` is refused with `session_required`.
- **Read keys are refused before the handler runs.** Any method but `GET` or
  `HEAD` with a read key answers 403 `api_key_read_only`, whatever the path, and
  still spends a request of the key's budget. The one exception is
  `POST /scripts/validate`: it is a `POST` only because a script does not fit
  in a query string, and it writes nothing.

Requests through a key are recorded in the organization's
[audit log](users-and-permissions.md#actions-taken-through-an-api-key) as the
member's own, with the key named beside them.

## Errors

A failed request answers a non-2xx status and a JSON body:

```json
{ "error": "api_key_read_only" }
```

`error` is a stable code, never prose — match on it. A few codes carry a
`details` object with the specifics, such as the name of the field that was
refused:

```json
{ "error": "field_invalid", "details": { "field": "pageSize", "max": 100 } }
```

These are the codes a caller can meet on any endpoint. The
[API Reference](api-reference.md) lists the ones particular to each endpoint.

| Status | Code | Meaning | What to do |
|---|---|---|---|
| 400 | `field_invalid` | A parameter, or a value the endpoint checks itself, is not one it accepts. `details.field` names it, and `details.max` gives the upper bound for `page`, `pageSize`, `wait` and `limit`. A malformed `Idempotency-Key` header names `Idempotency-Key`; an event cursor that is not a cursor at all names `after`. | Fix the value. |
| 400 | `field_required` | A required parameter, or a value the endpoint checks itself, is missing. `details.field` names it. | Send it. |
| 400 | `invalid_uuid` | An id in the path, the query or the body is not a UUID. `details.field` names which. | Check the id. |
| 400 | `invalid_request_body` | The body is not JSON, is not the shape the endpoint expects, or a field in it fails validation. When the gateway can name the failing field (a missing or over-long field, a value outside the allowed set), `details.field` names it and `details.reason` says what is wrong; a body that is not JSON, or a JSON body sent without `Content-Type: application/json`, has no details. | Check the body against the [reference](api-reference.md) and the [description](#the-api-description). |
| 400 | `invalid_path` | A path under `/api/public` that does not reduce to one canonical form — dot segments, encoded slashes. | Send the plain path. |
| 401 | `missing_auth_header` | No `Authorization` header. | Send `Authorization: Bearer td_…`. |
| 401 | `invalid_token` | The `Authorization` header carries no token. | Send the key after `Bearer `. |
| 401 | `invalid_api_key` | No key matches — mistyped, deleted, or a session token sent to this API. | Check the key; create a new one if it was deleted. |
| 401 | `api_key_revoked` | The key was revoked. It cannot be restored. | Create a new key. |
| 401 | `api_key_expired` | The key is past its expiry date. | Create a new key. |
| 401 | `api_key_owner_inactive` | The member the key acts as cannot currently act in the organization: their membership or account is disabled, or the account no longer exists. | It works again once the member is enabled. A removed member's keys are revoked instead (`api_key_revoked`). |
| 403 | `api_key_read_only` | A read key sent something other than `GET` or `HEAD`. | Use a write key for writes. |
| 403 | `totp_enrollment_required` | The organization, or a group the key's member belongs to, requires two-factor authentication and the member has not enrolled. | The member enrols in the dashboard; the key works again at once. |
| 403 | `insufficient_permissions` | The member lacks the organization permission the endpoint needs — `users` read for the directory, for instance. | Ask an administrator for the permission, or use another member's key. |
| 404 | `not_found` | No such resource — **or one the key's member may not see or change**. The two are deliberately the same answer. | Check the id, and the member's access to it. |
| 404 | `not_found` | No such route under `/api/public`. | Check the path against the [reference](api-reference.md). |
| 405 | `method_not_allowed` | The route exists, not with this method. | Check the method. |
| 409 | `already_exists` | A resource with this name or key already exists where you are creating it. | Pick another name, or update the existing one. |
| 409 | `idempotency_in_progress` | A `POST` with this `Idempotency-Key` is still being answered. Comes with `Retry-After: 1`. | Wait, and send the same request again. See [Idempotency](#idempotency). |
| 409 | `idempotency_outcome_unknown` | The request with this `Idempotency-Key` may have taken effect: it was cut off while it ran, its answer was too large to keep, or it was still marked as running after 5 minutes. It is not made again. | Check whether it took effect, then use a new key if it did not. |
| 410 | `cursor_expired` | The event feed cannot read on from this cursor: it is older than the events kept, from another organization, sealed before the platform key changed, or from before a database restore. `details.oldest` is a cursor to start again from. | Take a fresh snapshot, then read from `details.oldest`. See [Event feed](#when-a-cursor-stops-working). |
| 413 | `request_body_too_large` | The request body is over the gateway's limit (1 MiB unless the operator changed it). | Send less. |
| 422 | `idempotency_key_reused` | This `Idempotency-Key` was used with a different request — another method, path, query, content type or body. | Use a new key for a new request. |
| 429 | `rate_limited` | The key has spent its request budget for the window. | Wait `Retry-After` seconds. See [Rate limits](#rate-limits). |
| 429 | `too_many_unknown_keys` | Your address has sent too many requests with a token that names no key, or with no key at all. | Wait `Retry-After` seconds, and find what is sending bad keys. See [Rate limits](#rate-limits). |
| 429 | `idempotency_limit_reached` | The organization's budget for remembered answers is spent (see [Idempotency](#idempotency)). A request carrying a **new** `Idempotency-Key` is refused before it runs; requests without one are not affected. | Wait `Retry-After` seconds — when the budget's 24-hour window ends — or send without a key. |
| 429 | `too_many_event_polls` | Too many reads of the event feed are open at once. `details.bound` says whose: `key`, `user`, `org` or `process`. Comes with `Retry-After: 1`. | Let an open read return first. See [Cost and limits](#cost-and-limits). |
| 500 | `internal_error` | Something failed on the server. | Retry later; if it persists, the operator has the log entry. |
| 503 | `idempotency_unavailable` | A request carrying an `Idempotency-Key` cannot be made safely: the store that remembers keys is not answering. Comes with `Retry-After: 5`. | Retry after `Retry-After` seconds, with the same key. |

!!! note "Why a resource you cannot see is a 404, not a 403"
    A 403 would tell whoever holds the key that the id exists. Answering 404
    means a key learns nothing about resources outside its member's reach,
    including whether they are there at all. Organization-level sections are the
    exception — a 403 `insufficient_permissions` there says nothing about any
    one resource.

## Rate limits

Every key has a budget of **300 requests per minute** (`RATE_LIMIT_API_MAX` and
`RATE_LIMIT_API_WINDOW` on the server). The budget belongs to the key, not to
the address it calls from: twenty CI jobs behind one NAT, each with its own key,
each get 300. The key-authenticated API is exempt from the per-address budget
the dashboard's API uses for exactly that reason.

Each response to a request that reached the key's budget carries where the key
stands (none do while rate limiting is switched off):

| Header | Meaning |
|---|---|
| `X-RateLimit-Limit` | The key's budget per window. |
| `X-RateLimit-Remaining` | What is left of it in the current window. |
| `Retry-After` | On a 429 only: seconds until the next request can succeed. |

The budget is spent **before** the key is looked up, so every request that
reaches the key's budget counts, including ones that are then refused — a read
key's attempted write, a request for a resource that is not there. Back off on
429 for the `Retry-After` seconds rather than retrying at once; a tight retry
loop spends the next window too.

A request answered from a remembered `Idempotency-Key` is a request like any
other here: it spends one, and carries the headers.

**The event feed is charged differently.** A read of `GET /events` that waits
is one long request, and charging it on arrival would make a long-poll that
returns the moment something happens cost as much as one that polls in a loop.
So the feed charges for the work it does instead:

- a read that waits (`wait` above 0) has its **first look free**; every further
  look it makes while it waits spends one request, and so does an answer it
  gives without having waited — events already there on the first look;
- a read that does not wait (`wait=0`, the default) spends one request before
  it looks;
- a 410 `cursor_expired` spends one request;
- a key whose budget is already spent is refused with 429 `rate_limited` on
  arrival, before anything is looked up, without spending more.

A read makes at most three looks, so a read that waits costs one request, or
two when it needs its third look: a client that long-polls with `wait=30`
spends one or two requests a read, however long it waits. A read refused with
`too_many_event_polls` spends nothing. Feed answers carry no
`X-RateLimit-*` headers, because the read is charged as it goes rather than on
arrival; `Retry-After` comes with a 429 as everywhere else. How many reads may
be open at once is a separate bound — see [Cost and limits](#cost-and-limits).

There are two different 429s, and they want different responses:

| Code | Whose limit | Headers |
|---|---|---|
| `rate_limited` | **The key's**: it has made 300 requests this minute. | `X-RateLimit-*` and `Retry-After` |
| `too_many_unknown_keys` | **The address's**: 30 requests from it this minute presented a token that names no key, or no key at all (`RATE_LIMIT_API_FAILURE_*`). | `Retry-After` only |

The second one is a guard against somebody guessing keys. It counts tokens that
match no key, and requests that carry no key at all — no `Authorization` header,
or an empty one — which count exactly like a made-up key, so a flood without
credentials meets the same limit. A revoked or expired key is still somebody's
key, is bounded by its own budget, and does not count against the address — so
one forgotten runner with a stale key cannot shut out its neighbours. Once an
address is over the limit, every token from it is refused unread, **except a key
that has authenticated successfully in the last five minutes**, which is still
looked up as usual.

!!! warning "A new key behind a shared address"
    The exemption is earned by working. A key that has never authenticated — or
    has not for five minutes — has nothing to show, so behind an address that is
    already over its unknown-token limit even a perfectly good key is refused
    with `too_many_unknown_keys` until the window passes. Its first successful
    request after that marks it, and it is exempt from then on while it keeps
    working.

    If you see this code with a key you know is valid, something else behind the
    same address is sending bad keys — a job with a deleted key, a typo in a
    secret. Fix that, and wait out the `Retry-After`.

## Paging

Every list endpoint pages the same way:

| Parameter | Default | Allowed |
|---|---|---|
| `page` | `1` | 1 or more, up to a bound that depends on `pageSize` (`details.max` says it) |
| `pageSize` | `50` | 1 to 100 |

and answers the same envelope:

```json
{
  "items": [ … ],
  "total": 132,
  "page": 2,
  "pageSize": 50
}
```

`total` is the number of items across all pages. A `pageSize` over 100 is
refused with 400 `field_invalid` rather than quietly trimmed, so a client never
takes a short page for the end of the list.

Lists come back in a **fixed order**, so paging through one does not skip or
repeat items while nothing changes underneath:

| List | Order |
|---|---|
| Workspaces, projects, services, variables, webhooks, webhook bindings | Oldest first, by creation time, then id |
| Members | By display name, then id |
| Groups | By name, then id |
| Silences | By id |
| Results | Newest first, by start time, then id — or oldest first with `order=asc`, ties by id the same way |
| Script presets | By name, then id |
| Notification templates, and a project's templates | Oldest first, by creation time, then id |
| Alerts, `state=active` | Most recently seen first |
| Alerts, `state=all` | Newest episode first, by when it began, then id |
| Access entries (`GET /access/…`, not paged) | Groups, then users, each by name, then id |
| Agents (`GET /agents`, not paged) | By slug |

The event feed is not paged this way: it is read with a cursor — see
[Event feed](#event-feed).

There is no general filtering or sorting. The dashboard's own filter parameters,
`filters` and `sorters`, are not part of this API; they are refused with 400
`field_invalid` instead of ignored, so a client that sent them never reads an
unfiltered list as a filtered one. Filtering is by named parameters where an
endpoint needs one: `workspaceId` on projects and presets, `projectId` on
services, `resourceType` and `resourceId` on webhook bindings, `state` on
alerts, and on results `since`, `until`, `status`, `trigger` and `order` (see
[Reading results](#reading-results)).

## What the API covers

| Area | What you can do |
|---|---|
| **Key** | Read what the calling key is, and who it acts as. |
| **Workspaces** | List, create, read, rename, delete; switch every service in one on or off. |
| **Projects** | The same, inside a workspace. |
| **Services** | List, create — from a script, or from a preset's — read, update, delete; replace the script; switch on or off; **run now**, and follow that run by its [handle](#running-a-service-now); choose which probe agents may run it; read it with its recent runs in one call. |
| **Variables** | List, create, update and delete variables at organization, workspace, project and service scope; read the whole chain a workspace, project or service sees. Values come back [masked](#variables). |
| **Results** | List a service's runs, [filtered](#reading-results) by time, status and what started them, in either order; read one with its steps; read a step's saved response body inline, or [download it](#step-bodies) as it was stored. |
| **Scripts** | Judge a Lace script as a save would — the validator's findings and the platform's target and verified-domain rules — without saving it. A read key may do this. |
| **Presets** | The script presets a service can start from: list, create, read, rename or replace, delete. |
| **Notification templates** | The text notifications are written with: list, create, read, change, delete; bind them to projects and unbind them. |
| **Alerts** | Read the warning log — what the platform has noticed about its agents and runs — and dismiss an alert for yourself. |
| **Events** | A [feed](#event-feed) of what happens to everything the key's member may see: results recorded, status changes, resources and variables created, changed and deleted, alerts raised, runs settled. |
| **Metrics** | Current state and hourly history of a service, project or workspace; a service's statistics, per-endpoint series, most-failing assertions and failure heatmap. |
| **Silences** | Your own notification silences: list, create, read, change, remove. |
| **Access** | Who may see or change a workspace, project or service; grant, change and remove access. |
| **Directory** | The organization's members and groups — ids, names, emails — so a client can find whom to grant access to. |
| **Agents** | The probe agents a service can be restricted to, by slug, each with its health as the dashboard shows it. |
| **Webhooks** | Read the organization's webhooks (id, name, label and method — never where they send or what); attach them to and detach them from a resource; pause and resume an attachment. |

Every one of these goes through the same permission checks as the dashboard,
for the member the key acts as. Granting access to a resource, for instance,
needs write on that resource — so a key can hand out nothing its member could
not.

The [API Reference](api-reference.md) lists every endpoint.

### Variables

Variables are reachable at all four scopes — `/variables` for the
organization, `/workspaces/{id}/variables`, `/projects/{id}/variables` and
`/services/{id}/variables` — with the same body everywhere: a `key`, a `value`
and a `type` of `variable` (the default), `secret` or `metric`. See
[Variables](variables.md) for what each type means and how scripts reach them.

Values are stored encrypted for the `secret` and `variable` types, and the API
never decrypts them: their values come back as one fixed mask (`••••••`), at
every scope, with `"masked": true` on the variable so a client can tell the mask
from a value. Only `metric` values come back as they are. There is no reveal
endpoint — the dashboard's reveal is not part of the API — so treat what you
write to a `secret` or `variable` through the API as write-only.

### Reading results

`GET /services/{id}/results` lists a service's runs, newest first. Its
parameters narrow and order the list:

| Parameter | Keeps |
|---|---|
| `since`, `until` | Runs started at or after `since`, at or before `until`. ISO-8601 instants, both inclusive, compared to the second — start times are kept to the second. `until` before `since` is refused. |
| `status` | Runs with one of these statuses: `success`, `failure`, `timeout`, `error`, `skipped`. Repeat it (`status=failure&status=timeout`) or give them comma-separated (`status=failure,timeout`). |
| `trigger` | `schedule` — runs the cron started — or `manual`, runs somebody asked for, from the dashboard or the API. |
| `order` | `desc` (the default, newest first) or `asc` (oldest first). Ties go by id, in the same direction. |

Each result carries `trigger` too. Runs from before 0.4.59, and runs made while
gateways and schedulers of both versions ran side by side during the upgrade,
read as `schedule` whoever asked for them.

!!! warning "`order=asc` with `since` is not a cursor"
    A run is filed when it is ingested, not when it starts, so a run can appear
    *behind* the newest one you have already seen: a slow run started before a
    fast one lands after it. To follow new runs with this list, overlap `since`
    by a few minutes and skip the ids you have seen — or read the
    [event feed](#event-feed), which is made for following.

### Running a service now

`POST /services/{id}/run` asks for one run outside the schedule and answers
`202 Accepted` once the request is recorded, with a **run handle**:

```json
{ "ok": true, "requestedAt": "2026-10-03T09:41:07Z", "runId": "3d0c58e2-…" }
```

The run happens asynchronously, on a probe agent. `runId` is how you follow it:
its result is filed under that same id, so it is never confused with a
scheduled run that happens to land at the same moment. Ask where it stands with
`GET /services/{id}/runs/{runId}`:

```json
{
  "runId": "3d0c58e2-…",
  "state": "done",
  "requestedAt": "2026-10-03T09:41:07Z",
  "result": { "id": "3d0c58e2-…", "status": "success", "trigger": "manual", "…": "…" },
  "reason": null,
  "status": "success",
  "results": [ { "id": "3d0c58e2-…", "status": "success", "…": "…" } ]
}
```

| `state` | Meaning |
|---|---|
| `pending` | Asked for, not yet recorded. Poll again in a few seconds. |
| `done` | Recorded. `result` is the run, as the results list shows it, under the run's id; read it in full from `/results/{runId}`. |
| `skipped` | It was not made. `reason` says why (below); `result` is the skipped row in the history, when there is one. |
| `expired` | No result within the gateway's bound — 10 minutes unless the operator changed it. The request may have been lost. It **may still settle**: a result that arrives later is filed under the id, and the state follows it. |

A service that runs on several agents at once (the `simultaneous` probe mode)
makes one result per agent. `results` lists them all — an agent that did not run
it appears as a skipped result — and `result` is the one filed under the run's
id: the first that succeeded, or the first of all when none did. `status` is the
worst of them, in the order `failure`, `timeout`, `error`, `skipped`,
`success`; so `status: "skipped"` with `state: "done"` means some of the agents
did not run it. The run is `done` once every agent's result is in, or once the
bound has passed with at least one. A service that runs on one agent at a time
has one result, and `status` is its status.

A run is refused at once with 409 `service_inactive` when the service is
switched off, and 409 `script_missing` when it has no script yet: neither would
ever produce a result to wait for. Anything that stops it later is answered on
the handle as `skipped`, with a `reason` — grouped here by what to do about it:

| Do this | Reasons |
|---|---|
| **Ask again later** | `run_already_running`, `run_already_queued` — a run of the service was already under way or waiting; its result is in `/results` under another id. `run_in_service_window` — the service is in its maintenance window. `dispatch_queue_full` — the platform is over its probing capacity. |
| **Wait at least 5 minutes, or verify the domain** | `unverified_throttle` |
| **Fix the service or its configuration** | `run_service_inactive`, `run_script_missing` — switched off, deleted or left without a script after you asked. `target_*` — an address this installation does not probe, or a target that asked not to be. The other `unverified_*` reasons — the verified-domain limits. |
| **Tell the operator** | `run_held` — held until an operator clears it; waiting does not help. `run_not_delivered` — no scheduler was listening, so nothing will run it. `variable_unreadable`, `no_eligible_agent`, `agent_unreachable`, `agent_rejected`, `dispatch_error`. |

New reasons can appear; treat one you do not know as a platform problem. The
`run_*` reasons are answers to a run somebody asked for: they are recorded in
the service's history as skipped runs, and raise no alert. See
[Skipped probes](results.md#skipped-probes).

Poll the handle every few seconds while it is `pending`. Two alternatives:

- **Wait on the feed.** Take a cursor from the [event feed](#event-feed)
  *before* asking for the run, then read on from it for the `run.settled` event
  whose `runId` is yours. It arrives when the run reaches `done` or `skipped` —
  never for `expired`, which is only what the handle says once nothing has
  come.
- **Retry safely.** Send the request with an [`Idempotency-Key`](#idempotency):
  a repeat with the same key answers with the same `runId` and runs nothing.
  Once a run has ended `skipped` or `expired`, asking again is a new request —
  send a new key.

A handle is kept as long as the run's result would be (the organization's
result retention), and is 404 to anybody who may not read the service's
results, as it is for an id that is not a run of that service.

## Step bodies

When a service saves response bodies, each step of a result says so with
`"hasBody": true`, and the body is read from
`GET /services/{id}/results/{resultId}/steps/{stepId}/body`. It comes back
inline, in JSON — never as a link to wherever it is stored:

```json
{
  "content": "{\"status\":\"ok\",\"version\":\"4.2.1\"}",
  "contentType": "application/json",
  "encoding": null
}
```

| Field | Meaning |
|---|---|
| `content` | The body. |
| `contentType` | The content type the response was stored with, or `null` when none was recorded or it is not one the gateway repeats back. |
| `encoding` | `null` when `content` is the body's text as it is. `"base64"` when `content` is the base64 of the stored bytes — for a body that is not UTF-8 text, or text containing control characters other than tab, newline and carriage return. Decode it before use. |

Bodies served this way are capped at **4 MiB** of stored bytes; a larger one
is refused with 413 `body_too_large`. A client that takes nothing of the answer
for 20 seconds, or has not taken all of it after 10 minutes, is cut off.

`GET …/steps/{stepId}/body/raw` serves the same body **as it was stored** —
the bytes, not JSON — up to the body store's own limit, 32 MiB:

```bash
curl -sS --fail-with-body -o body.bin \
  "$TRACEDOWN/api/public/v1/services/$SVC/results/$RESULT/steps/$STEP/body/raw" \
  -H "Authorization: Bearer $TRACEDOWN_KEY"
```

It answers with the stored content type when the gateway repeats it
(`application/octet-stream` otherwise), `Content-Length`,
`Content-Disposition: attachment`, `X-Content-Type-Options: nosniff` and
`Cache-Control: private, no-store` — a body is whatever the probed endpoint
sent, so it is never to be rendered or cached as if it were the API's own.
`HEAD` answers the headers alone, without reading the body. The same bound
applies: a client that takes nothing for 20 seconds, or has not taken the
whole body after 10 minutes however steadily it reads, is cut off.

Besides `200`, both endpoints answer `204` when the step has no stored body,
and 410 `body_gone`, 413 `body_too_large` or 503 `body_store_unavailable` — see
the [body endpoints](api-reference.md#step-body-answers) for what each means.
Their errors are JSON either way.

The run's `rawResult`, on the result detail, is the probe result as the Lace
executor produced it — except that storage locators are blanked: `bodyPath`
and keys like it are `null`. Bodies are reached
through `steps[].hasBody` and the body endpoint, never through `rawResult`.

## Idempotency

A pipeline step that times out leaves you not knowing whether its request was
made. Sending it again could create a second service or a second run. Every
`POST` in the API — except `POST /scripts/validate`, which has nothing to do
twice — takes an **`Idempotency-Key`** header that makes the repeat safe:

```bash
curl -sS -X POST "$TRACEDOWN/api/public/v1/services/$SVC/run" \
  -H "Authorization: Bearer $TRACEDOWN_KEY" \
  -H "Idempotency-Key: deploy-4711-smoke-run"
```

The key is 1 to 128 printable ASCII characters of your choosing, unique per
request; anything else is 400 `field_invalid` naming `Idempotency-Key`. Keys
belong to the API key that sent them, so two clients with keys of their own
cannot collide. The gateway remembers the request under it — the method, the
path, the query parameters, the content type and the body — and a repeat with
the same key and the same request is **never made a second time**. What the
repeat gets depends on how the first one ended:

| The first request | A repeat with the same key gets |
|---|---|
| Succeeded (2xx) | The same answer — status, content type and body — for **24 hours**, marked `Idempotent-Replayed: true`. Nothing runs again. |
| Was refused or failed (4xx, 5xx) | Nothing: it was not remembered. The repeat runs as a new request, and may succeed. |
| Is still being answered | 409 `idempotency_in_progress`, with `Retry-After: 1`. |
| Was cut off while it ran — its client went away — or was still marked as running after 5 minutes | 409 `idempotency_outcome_unknown`, for 24 hours. |
| Succeeded with an answer over **256 KiB** | 409 `idempotency_outcome_unknown`, for 24 hours. The first answer said so, with `Idempotency-Status: not-kept`. |

The same key with a **different** request is 422 `idempotency_key_reused`.

A few things follow from those rules:

- **Only successes are remembered.** A 409, a 400 or a 500 is not an answer to
  keep: fix the request and send it again, with the same key or a new one.
- **An unknown outcome is never run again.** The request may have taken
  effect; the gateway cannot tell, so it will not risk doing it twice. Check —
  list the services, read the run — and if it did not happen, send it with a
  **new key**.
- **A new attempt needs a new key.** The key names one request, not one kind
  of request. A pipeline that runs again tomorrow, or asks for another run of
  a service whose last one ended `skipped` or `expired`, uses a new key; reuse
  one only for a repeat of the very same request. Something your pipeline
  already has unique per attempt — its run id, a commit and a step name —
  makes a good key.
- **A replay checks membership, not permission.** Before it replays a
  remembered answer, the gateway checks that the key's member is still in the
  organization. It does not run the route's own permission check again: the
  answer is what the member was given when they could ask for it.
- **A replay restores the body, not the headers.** Headers the first answer
  carried, beyond its content type, are not kept; the replay carries
  `Idempotent-Replayed: true` and the current rate-limit headers instead.

What is remembered — kept answers and unknown outcomes, at the size they are
stored — counts against a **budget per organization**, 64 MiB unless the
operator set another (`IDEMPOTENCY_ORG_BUDGET_BYTES`), in a window fixed at
24 hours from the first request it counts. Once it is spent, a request with a
new key is refused before it runs, with 429 `idempotency_limit_reached` and a
`Retry-After` until the window ends. Requests without a key, and repeats of
keys already held, are not affected.

The keys are kept in the operational Redis (Redis A), shared by every gateway.
When it does not answer, a request carrying a key is refused with 503
`idempotency_unavailable` and `Retry-After: 5`, rather than run without the
promise; repeat it with the same key. A request without a key does not depend
on Redis this way.

## Event feed

`GET /events` is a feed of what happens to everything the key's member may see,
in the order it was written. It is how a client learns that a result was
recorded, a service changed status or a run it asked for settled, without
polling every service's results.

```bash
curl -s "$TRACEDOWN/api/public/v1/events?after=$CURSOR&wait=30" \
  -H "Authorization: Bearer $TRACEDOWN_KEY"
```

```json
{
  "items": [
    {
      "id": "0b6f2d4e-…",
      "type": "result.recorded",
      "occurredAt": "2026-10-09T09:41:07Z",
      "resource": { "type": "service", "id": "7c1d…" },
      "data": {
        "resultId": "e3a9…",
        "status": "failure",
        "runDurationMs": 812,
        "reason": null,
        "projectId": "51aa…",
        "workspaceId": "90fe…"
      }
    }
  ],
  "next": "ev2.Xq4…",
  "more": false
}
```

| Parameter | Meaning |
|---|---|
| `after` | A cursor: the `next` of an earlier read. Without it, the read starts from now. |
| `wait` | Seconds to wait for an event when there is none yet, 0 to 30. Default 0: answer at once. |
| `types` | Only these event types — comma-separated, or the parameter repeated. |
| `limit` | Events per page, 1 to 100. Default 100. |

Read on by passing `next` as `after`. `next` moves even when `items` is empty,
so always keep the latest one. `more: true` means more events may be there
already: read on at once rather than waiting. A page holds at most `limit`
events, or one more when a result and the status change it caused arrive
together. A long-poll (`wait=30`) returns as soon as the first event arrives,
or with an empty page when none came.

### Event types

`data` carries exactly these fields for each type, and never a variable's value
or any other secret:

| Type | `resource.type` | `data` |
|---|---|---|
| `result.recorded` | `service` | `resultId`, `status`, `runDurationMs`, `reason`, `projectId`, `workspaceId` |
| `service.status_changed` | `service` | `status`, `previousStatus`, `resultId` |
| `workspace.created`, `.updated`, `.deleted` | `workspace` | — |
| `project.created`, `.updated`, `.deleted` | `project` | `workspaceId` |
| `service.created`, `.updated`, `.deleted` | `service` | `projectId`, `workspaceId` |
| `variable.created`, `.updated`, `.deleted` | `variable` | `scope`, `scopeId`, `key` |
| `alert.raised` | `alert` | `type`, `subject`, `severity` |
| `run.settled` | `service` | `runId`, `serviceId`, `state`, `status`, `reason`, `superseded` |

- **`result.recorded`** — a run was recorded. `status` is its status
  (`success`, `failure`, `timeout`, `error`, `skipped`); skipped runs are
  included, with their `reason` — set only for them — and a null
  `runDurationMs`.
- **`service.status_changed`** — follows the result that changed the service's
  status. `previousStatus` is null on a service's first run.
- **`variable.*`** — `scope` is `org`, `workspace`, `project` or `service` and
  `scopeId` that scope's id; `key` is null once the variable has been purged. A
  script's [writeback](variables.md#writeback) shows up here too: a
  `variable.created` for a new key, a `variable.updated` when a value changed.
- **`alert.raised`** — a new episode of a [system alert](notifications.md#system-alerts).
- **`run.settled`** — a run asked for with `POST /services/{id}/run` reached
  `done` or `skipped` (`state`). `status` is its worst result's, null when it
  never ran (`reason` `run_not_delivered`); `reason` is set only when the whole
  run was skipped. A run can settle a second time — a skip that a late result
  replaces, a result arriving after `run_not_delivered` — with
  `superseded: true`: the last `run.settled` for a `runId` wins. An `expired`
  run is never an event.

`occurredAt` is when the run started for a result, when the episode began for
an alert, and when the change was made for everything else. `id` is unique per
event, and the same event read twice has the same id. New types can be added
within v1; skip the ones you do not know, or ask for the ones you do with
`types`.

### What a client sees

Each read decides what the caller sees **now**, with the checks the dashboard's
reads of the same resources make — read on the service for its results, status
changes and settled runs; read on the workspace, project or service for its own
events and its variables; Settings **Read** for organization variables;
Settings **Write** for alerts, as for the warning log. So a grant withdrawn, a
member removed, a key revoked or two-factor newly required stops delivery from
the next look, even within one long-poll. A grant given shows only what happens
from then on: re-list what the grant reveals. See
[Users & Permissions](users-and-permissions.md#the-event-feed).

### Starting, and staying in step

The feed tells you what changed; your own copy of the state comes from the
lists. Start in this order, so nothing falls between the two:

1. **Take a cursor.** Read once without `after` (`wait=0`) and keep `next`.
2. **Take your snapshot** — list the services, results or whatever you track.
3. **Read from the cursor**, applying each event to the snapshot by its `id`.

Delivery is **at least once**. An event can come twice — a read retried after a
lost answer — and one read just after the snapshot can show what the snapshot
already has. Keep the ids you have applied and skip repeats, and make applying
an event safe to do twice.

Some things are not announced, and a client keeping a copy has to allow for
them:

- **Children of a deleted container.** Deleting a workspace or project deletes
  everything in it, and there is one event, for the container. Drop its
  projects, services and variables yourself.
- **Variables the platform seeds.** A new service gets some variables that are
  not announced: on `service.created`, re-list the service's variables.
- **The end of an alert.** Nothing clears an alert by an event. An alert ends
  when a user dismisses it — for that user alone — and a condition that
  returns after a quiet spell is a new episode. An integration that shows
  alerts re-reads `GET /alerts` rather than tracking them from `alert.raised`.
  Dismissing is per user and is not written to the audit log.
- **Expired runs**, groups, memberships and webhooks' variables.

**Quiet periods** need nothing special: a read that finds nothing still moves
`next`, so a cursor you keep reading never falls behind, however little
happens. Only a cursor left unread for longer than events are kept expires.

### When a cursor stops working

Events are kept for **7 days**. A cursor older than that answers 410
`cursor_expired`, with `details.oldest`: a cursor to start again from. Events
between the two may be gone, so take a new snapshot first, then read from
`details.oldest`. The same 410 answers:

- a cursor from **another organization** — a cursor works only for the
  organization it was given in;
- every cursor sealed before the operator **changed the platform key**;
- every cursor once the **database has gone back in time** — a backup
  restored, a point-in-time recovery, a dump loaded elsewhere. The feed then
  starts again from the present.

A value that is not a cursor at all is 400 `field_invalid` naming `after`.

### Cost and limits

A read looks for events at most three times, spread over its `wait`, and then
answers — even before `wait` is up. How the looks are charged to the key's
request budget is under [Rate limits](#rate-limits).

Reads that are open at once are bounded: **2 per key, 6 per user and 24 per
organization**, across every gateway. Beyond that, a read is refused with 429
`too_many_event_polls`, `details.bound` naming which bound was reached (`key`,
`user`, `org`, or `process` for a gateway's own ceiling) and `Retry-After: 1`.
One long-poll per key at a time is the intended pattern. A member who can see
nothing at all is answered at once and holds no slot.

!!! note "A feed that stops moving"
    The feed delivers what was written below the oldest transaction still open
    on the database server, so that nothing written by a slow transaction is
    ever passed over. The price is that a transaction left open **anywhere on
    the database server** — another application, another database, a `psql`
    session with a `BEGIN` and no `COMMIT` — holds the feed back until it ends.
    Nothing is lost; it is delivered once the transaction ends. The operator's
    side is in [Troubleshooting](../admin/troubleshooting.md#the-event-feed-delivers-nothing-new).

## The API description

The whole API is described in an OpenAPI 3.1 document, served at:

```text
GET /api/openapi/public/v1.json
```

It needs no key — a client reads it before it has a key working — and sits
outside `/api/public` for that reason; it is metered per address like any
unauthenticated request. Every operation in it has an `operationId`
(`listWorkspaces`, `createService`, `getStepBody` and so on), a summary, its
parameters, its request and response schemas with their enumerations, formats
and length limits, and for each status the `error` codes behind it, the shared
error shape, and the rate-limit headers on 429. The `Idempotency-Key` header
is declared on every operation that takes it, with `Idempotent-Replayed` and
`Idempotency-Status` on its successes and `Retry-After` where an answer
carries one; the event types and the `data` fields of each are tabled in
`listEvents`; the raw body download is described as bytes, not JSON. The
server URL in it is relative, so it is correct wherever your gateway is
published.

What the description does not carry: which operations a read key may call —
any `GET` or `HEAD`, decided by the method alone, and `POST /scripts/validate`;
the permission each operation needs (see the [reference](api-reference.md));
and `HEAD`, which every `GET` operation also answers.

That makes it the input for tooling rather than something to read by hand:

- **Client generators.** Point an OpenAPI generator at the URL to get a typed
  client in your language:

    ```bash
    npx @openapitools/openapi-generator-cli generate \
      -i "$TRACEDOWN/api/openapi/public/v1.json" -g python -o ./tracedown-client
    ```

    The paths in the description are full paths (`/api/public/v1/…`) and its
    server is relative to where it was served. A client generated from a saved
    copy needs its host set to your Tracedown address — `$TRACEDOWN`, without
    `/api/public/v1`.

- **Agent toolkits.** Frameworks that turn an OpenAPI document into tools for a
  language-model agent take the same file; each `operationId` becomes a tool,
  with the summary as its description. Give such an agent a **read** key unless
  it is meant to change things, and remember that whatever it does is recorded
  as the key's member.

If your web server passes only selected paths to the gateway, it must pass
`/api/openapi/` as well as `/api/public/`.

## What is not in v1

The API covers the monitoring resources. These stay in the dashboard:

- **Organization administration** — members, invites, groups, organization
  permissions, organization settings, ownership, deleting the organization.
  The directory endpoints only *read* members and groups.
- **The audit log.**
- **Probe agent and body store administration** — enrolling agents, assigning
  stores. The agents endpoint lists slugs, labels and health and nothing more.
- **Creating or editing webhooks.** Existing ones can be attached and
  detached.
- **Domains** — verifying the domains your probes target.
- **Revealing a variable's value.**
- **Bulk operations and data export.**
- **Your own account** — keys, sessions, password, email, two-factor. A key
  cannot create, list or revoke keys.

### Compatibility

Within v1, changes are **additive only**: new endpoints, new optional request
fields, new response fields. Nothing that works against v1 today stops working —
no endpoint is removed, no field renamed or retyped, no optional field made
required. New values can appear in enumerated fields — a run's `state`, a
result's `status` and `trigger`, a skip `reason` — and new event types and
`error` codes can appear; treat an unknown value as you would the nearest one
you know, an unknown event type as one to skip, and an unknown error code as
you would an unknown failure. Write clients that
ignore response fields they do not know. A change
that cannot be made additively becomes `/api/public/v2`, alongside v1.

## A complete example

From an empty organization to a probe result and back, with nothing but a
**write** key. Run the steps as one script (`bash tracedown-example.sh`): it
uses [`jq`](https://jqlang.org) to pick fields out of responses, and curl 7.76
or later for `--fail-with-body`, so a refused request stops the script and
prints the `{"error": …}` body. It needs a gateway on 0.4.59 or later.

Three things have to be true first:

- **You have a write key.** In the dashboard, **My account → API keys → New API
  key**, access **Read and write**.
- **The key's member needs organization Workspaces Write**, which is what
  creating a workspace takes. Without it step 1 answers 403
  `insufficient_permissions`.
- **The target domain should be verified.** On a default install
  (`TRUSTED_DOMAIN_MODE=false`), a probe against a domain the organization has
  not verified under **Settings → Domains** runs restricted: no response bodies
  are saved, the schedule cannot be shorter than five minutes, and the script
  may make at most three calls. The example still runs, but step 6 finds no
  step with a body. See [Domain trust](../install/configuration.md#domain-trust).

The script starts by setting the address, the key and a prefix for its
`Idempotency-Key`s — unique per run of the script, so that a repeat of one of
its requests is recognised and a new run of the script is not mistaken for
one — and a helper for calls:

```bash
set -euo pipefail

export TRACEDOWN=https://tracedown.example.com
export TRACEDOWN_KEY=td_...   # from My account → API keys
ATTEMPT="example-$(date +%s)" # in CI, use the pipeline's own run id

api() {  # api METHOD PATH [JSON] [IDEMPOTENCY-KEY]
  curl -sS --fail-with-body -X "$1" "$TRACEDOWN/api/public/v1$2" \
    -H "Authorization: Bearer $TRACEDOWN_KEY" \
    -H "Content-Type: application/json" \
    ${4:+-H "Idempotency-Key: $4"} \
    ${3:+--data "$3"}
}
```

**1. Create a workspace and a project.** Creates answer `200` with the new
resource. Each carries an `Idempotency-Key`, so running the same line again —
after a dropped connection, say — can never make a second one: it gets the
first answer back, or 409 `idempotency_outcome_unknown` when the first was cut
off mid-way, which says to look before trying again. See
[Idempotency](#idempotency).

```bash
WS=$(api POST /workspaces '{"name": "Checkout"}' "$ATTEMPT-ws" | jq -r .id)

PROJ=$(api POST /projects \
  "{\"workspaceId\": \"$WS\", \"name\": \"Payments API\"}" "$ATTEMPT-proj" | jq -r .id)
```

**2. Create a service.** `schedule` is a cron expression (every five minutes
when left out). This one runs once a year, on 1 January, so the only result in
the next steps is the run asked for in step 5. The service starts switched off,
with no script yet.

```bash
api POST /services \
  "{\"projectId\": \"$PROJ\", \"name\": \"Health\", \"schedule\": \"0 0 1 1 *\", \"saveResponseBodies\": true}" \
  "$ATTEMPT-svc" > service.json
SVC=$(jq -r .id service.json)
VERSION=$(jq -r .version service.json)
```

**3. Check the script, then give it to the service.** `POST /scripts/validate`
judges a script exactly as a save would — the Lace validator, then the
platform's target and verified-domain rules — and saves nothing. With
`serviceId` it judges it with that service's variables and schedule. `valid`
says whether anything the key's member can judge would refuse it, and
`complete` whether that was everything a save judges. It is false whenever a
rule could not be judged: a call's host comes from a variable with no value
here, or one the member may not read; or the verified-domain rules apply and
the member cannot read the organization's domains, or no `serviceId` was
given — the interval rule needs a service's schedule.

```bash
# Put your own endpoint in place of https://api.example.com/health.
SCRIPT='get("https://api.example.com/health").expect(status: 200)'

api POST /scripts/validate \
  "$(jq -n --arg s "$SCRIPT" --arg svc "$SVC" '{script: $s, serviceId: $svc}')" > validation.json
jq '{valid, complete, errors, limits}' validation.json
[ "$(jq -r .valid validation.json)" = true ] || { echo "the script would be refused" >&2; exit 1; }
```

Then save it. A script write names the `version` it replaces, so two writers
cannot silently overwrite each other; a stale one is refused with 409
`version_conflict`. A script that does not validate is refused with 400
`field_invalid`, with the same findings in `details.errors`. As in the
dashboard, the first save of a service that has never been saved (still at
`version` 1) switches it on. That enable goes through the same checks as any
other; if it is refused, the script is still saved and the service stays off.

```bash
api PATCH "/services/$SVC/script" "$(jq -n --arg s "$SCRIPT" --arg v "$VERSION" '{
  script: $s,
  version: ($v | tonumber)
}')"
```

**4. Check it is on.**

```bash
api GET "/services/$SVC" | jq .isActive
# true
```

`PATCH /services/{id}/toggle` with `{"isActive": true}` is for switching a
paused service back on; it checks that the script is there and valid.

Steps 2 to 4 can also be one call: `POST /services` accepts `script` and
`isActive` as well — or `presetId`, to start from a saved preset's script. A
script there is saved as a first script save, which switches the service on
unless `isActive` is `false`. If the script or the enable is refused, the call
leaves nothing behind — no service and no audit entries — and the error is
returned.

**5. Run it now, and follow the run.** The answer carries the run's handle,
`runId`; its result will be filed under that id. The request carries an
`Idempotency-Key` too, so a retry of this line cannot start a second run. The
loop polls the handle every five seconds while it is `pending`, for up to five
minutes.

```bash
RUN=$(api POST "/services/$SVC/run" "" "$ATTEMPT-run" | jq -r .runId)

for i in $(seq 1 60); do
  api GET "/services/$SVC/runs/$RUN" > run.json
  [ "$(jq -r .state run.json)" != pending ] && break
  sleep 5
done

case "$(jq -r .state run.json)" in
  done)    ;;
  skipped) echo "not run: $(jq -r .reason run.json)" >&2; exit 1 ;;
  *)       echo "no result: $(jq -r .state run.json)" >&2; exit 1 ;;
esac
```

`skipped` comes with a `reason` saying what to do; `expired` means no result
came within the gateway's bound, and `pending` that none has come yet — see
[Running a service now](#running-a-service-now). Instead of polling, a client
already reading the [event feed](#event-feed) can take a cursor before the
`POST` and wait for the `run.settled` event naming this `runId`.

**6. Read the result and download a step's body.** The result is filed under
the run's id. `/body/raw` serves the body as it was stored, of any size up to
the store's 32 MiB; `/body` would give it inline, as JSON, up to 4 MiB.

```bash
api GET "/services/$SVC/results/$RUN" > result.json
jq '{status, trigger, steps: [.steps[] | {stepNum, statusCode, hasBody}]}' result.json

STEP=$(jq -r '[.steps[] | select(.hasBody)][0].id // empty' result.json)
if [ -n "$STEP" ]; then
  curl -sS --fail-with-body -o body.bin \
    "$TRACEDOWN/api/public/v1/services/$SVC/results/$RUN/steps/$STEP/body/raw" \
    -H "Authorization: Bearer $TRACEDOWN_KEY"
fi
```

`status` is the run's outcome — see
[what a status means](results.md#what-a-status-means). In a pipeline, this is
the point to fail the build on anything but a success. This `exit` line ends
the script there, before the clean-up; put it after step 7 to clean up either
way:

```bash
[ "$(jq -r .status result.json)" = success ] || exit 1
```

**7. Clean up.** Deleting a workspace takes its projects and services with it;
here each is deleted in turn. Deletes answer `200` with `{"ok": true}`, and the
resource then reads as 404.

```bash
api DELETE "/services/$SVC"
api DELETE "/projects/$PROJ"
api DELETE "/workspaces/$WS"
```

Every change above is in the organization's audit log, attributed to the key's
member, *via key* and your key's name. When the key is no longer needed, revoke
or delete it under **My account → API keys**.

## Related

- [API Reference](api-reference.md) — every endpoint, its parameters and its
  responses.
- [Your Account](account.md#api-keys) — creating, revoking and deleting keys.
- [Users & Permissions](users-and-permissions.md#api-key-oversight) — oversight
  of an organization's keys, and how the audit log attributes key activity.
- [Configuration](../install/configuration.md#security) — the rate budget on
  the server, the [key limit](../install/configuration.md#api-keys), and the
  [run handle bound and idempotency budget](../install/configuration.md#run-handles-and-idempotent-requests).
