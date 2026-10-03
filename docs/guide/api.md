---
description: "The Tracedown API for scripts, pipelines and agents: API keys, authentication, errors, the per-key rate budget, paging, step bodies, the OpenAPI description, and a complete worked example."
---
# The API

!!! note "Tracedown 0.4.49 and later"
    This page describes the API as served from release 0.4.49 on. Release 0.4.48
    serves only `GET /key` under `/api/public/v1`.

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
and ends with a [worked example](#a-complete-example). Every endpoint is listed
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
  and `HEAD` requests, **write** keys may do whatever their member may;
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
| Bodies | JSON in, JSON out. A request with a body must send `Content-Type: application/json`. |
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
  still spends a request of the key's budget.

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
| 400 | `field_invalid` | A parameter, or a value the endpoint checks itself, is not one it accepts. `details.field` names it, and `details.max` gives the upper bound for `page` and `pageSize`. | Fix the value. |
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
| 413 | `request_body_too_large` | The request body is over the gateway's limit (1 MiB unless the operator changed it). | Send less. |
| 429 | `rate_limited` | The key has spent its request budget for the window. | Wait `Retry-After` seconds. See [Rate limits](#rate-limits). |
| 429 | `too_many_unknown_keys` | Your address has sent too many requests with a token that names no key, or with no key at all. | Wait `Retry-After` seconds, and find what is sending bad keys. See [Rate limits](#rate-limits). |
| 500 | `internal_error` | Something failed on the server. | Retry later; if it persists, the operator has the log entry. |

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
| Results | Newest first, by start time, then id |
| Access entries (`GET /access/…`, not paged) | By name, then id |

There is no general filtering or sorting. The dashboard's own filter parameters,
`filters` and `sorters`, are not part of this API; they are refused with 400
`field_invalid` instead of ignored, so a client that sent them never reads an
unfiltered list as a filtered one. Filtering is by named parameters where an
endpoint needs one: `workspaceId` on projects, `projectId` on services,
`resourceType` and `resourceId` on webhook bindings, and `since` on results.

## What the API covers

| Area | What you can do |
|---|---|
| **Key** | Read what the calling key is, and who it acts as. |
| **Workspaces** | List, create, read, rename, delete; switch every service in one on or off. |
| **Projects** | The same, inside a workspace. |
| **Services** | List, create, read, update, delete; replace the script; switch on or off; **run now**; choose which probe agents may run it; read it with its recent runs in one call. |
| **Variables** | List, create, update and delete variables at organization, workspace, project and service scope; read the whole chain a workspace, project or service sees. Values come back [masked](#variables). |
| **Results** | List a service's runs, read one with its steps, read a step's saved response body. |
| **Metrics** | Current state and hourly history of a service, project or workspace; a service's statistics, per-endpoint series, most-failing assertions and failure heatmap. |
| **Silences** | Your own notification silences: list, create, read, change, remove. |
| **Access** | Who may see or change a workspace, project or service; grant, change and remove access. |
| **Directory** | The organization's members and groups — ids, names, emails — so a client can find whom to grant access to. |
| **Agents** | The probe agents a service can be restricted to, by slug. |
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

### Running a service now

`POST /services/{id}/run` asks for one run outside the schedule and answers
`202 Accepted` with the time the run was asked for:

```json
{ "ok": true, "requestedAt": "2026-10-03T09:41:07Z" }
```

The run happens asynchronously, on a probe agent; its result appears under the
service's results when it lands. Poll `GET /services/{id}/results` with
`since` set to `requestedAt` to see only runs that started after the request.
`requestedAt` is in whole seconds, and `since` is taken to the second, so a run
that started in the same second as the request is included.
On a short schedule a scheduled run can land first, and a result does not say
what started it, so the first item to appear is not guaranteed to be yours.

A run is refused with 409 `service_inactive` when the service is switched off,
and 409 `script_missing` when it has no script yet: neither would ever produce
a result to wait for.

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

Bodies served this way are capped at **4 MiB** of stored bytes. Larger bodies
are not served by v1.

Besides `200`, the endpoint answers `204` when the step has no stored body, and
410 `body_gone`, 413 `body_too_large` or 503 `body_store_unavailable` — see the
[body endpoint](api-reference.md#step-body-answers) for what each means.

The run's `rawResult`, on the result detail, is the probe result as the Lace
executor produced it — except that storage locators are blanked: `bodyPath`
and keys like it are `null`. Bodies are reached
through `steps[].hasBody` and the body endpoint, never through `rawResult`.

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
error shape, and the rate-limit headers on 429. The
server URL in it is relative, so it is correct wherever your gateway is
published.

What the description does not carry: which operations a read key may call —
any `GET` or `HEAD`, decided by the method alone; the permission each operation
needs (see the [reference](api-reference.md)); and `HEAD`, which every `GET`
operation also answers.

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
  stores. The agents endpoint lists slugs and labels and nothing more.
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
required. New values can appear in enumerated fields and new `error` codes can
appear; treat unknown ones as you would an unknown failure. Write clients that
ignore response fields they do not know. A change
that cannot be made additively becomes `/api/public/v2`, alongside v1.

## A complete example

From an empty organization to a probe result and back, with nothing but a
**write** key. Run the steps as one script (`bash tracedown-example.sh`): it
uses [`jq`](https://jqlang.org) to pick fields out of responses, and curl 7.76
or later for `--fail-with-body`, so a refused request stops the script and
prints the `{"error": …}` body.

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

The script starts by setting the address and the key, and a helper for calls:

```bash
set -euo pipefail

export TRACEDOWN=https://tracedown.example.com
export TRACEDOWN_KEY=td_...   # from My account → API keys

api() {  # api METHOD PATH [JSON]
  curl -sS --fail-with-body -X "$1" "$TRACEDOWN/api/public/v1$2" \
    -H "Authorization: Bearer $TRACEDOWN_KEY" \
    -H "Content-Type: application/json" \
    ${3:+--data "$3"}
}
```

**1. Create a workspace and a project.** Creates answer `200` with the new
resource.

```bash
WS=$(api POST /workspaces '{"name": "Checkout"}' | jq -r .id)

PROJ=$(api POST /projects \
  "{\"workspaceId\": \"$WS\", \"name\": \"Payments API\"}" | jq -r .id)
```

**2. Create a service.** `schedule` is a cron expression (every five minutes
when left out). This one runs once a year, on 1 January, so the only result in
the next steps is the run asked for in step 5. The service starts switched off,
with no script yet.

```bash
api POST /services \
  "{\"projectId\": \"$PROJ\", \"name\": \"Health\", \"schedule\": \"0 0 1 1 *\", \"saveResponseBodies\": true}" \
  > service.json
SVC=$(jq -r .id service.json)
VERSION=$(jq -r .version service.json)
```

**3. Give it a script.** A script write names the `version` it replaces, so two
writers cannot silently overwrite each other; a stale one is refused with 409
`version_conflict`. The script is validated before it is saved. A script that
does not validate is refused with 400 `field_invalid`; `details.errors` lists
what the validator found and `details.reason` gives the first message. Write
and check it in the dashboard's editor, or with a Lace validator (see
[Writing Probes](writing-probes.md)), before sending it. As in the dashboard,
the first save of a service that has never been saved (still at `version` 1)
switches it on. That enable goes through the same checks as any other; if it
is refused, the script is still saved and the service stays off.

```bash
# Put your own endpoint in place of https://api.example.com/health.
api PATCH "/services/$SVC/script" "$(jq -n --arg v "$VERSION" '{
  script: "get(\"https://api.example.com/health\").expect(status: 200)",
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
`isActive` as well. A `script` there is saved as a first script save, which
switches the service on unless `isActive` is `false`. If the script or the
enable is refused, the call leaves nothing behind — no service and no audit
entries — and the error is returned.

**5. Run it now, and wait for the result.** The `exit` line ends the script if
no result has appeared after 40 seconds.

```bash
REQUESTED=$(api POST "/services/$SVC/run" | jq -r .requestedAt)

RESULT=""
for i in $(seq 1 20); do
  RESULT=$(api GET "/services/$SVC/results?since=$REQUESTED&pageSize=1" | jq -r '.items[0].id // empty')
  [ -n "$RESULT" ] && break
  sleep 2
done
[ -n "$RESULT" ] || { echo "no result yet" >&2; exit 1; }
```

On a short schedule, a scheduled run can land before yours — see
[Running a service now](#running-a-service-now).

**6. Read the result and a step's body.**

```bash
api GET "/services/$SVC/results/$RESULT" > result.json
jq '{status, steps: [.steps[] | {stepNum, statusCode, hasBody}]}' result.json

STEP=$(jq -r '[.steps[] | select(.hasBody)][0].id // empty' result.json)
if [ -n "$STEP" ]; then
  api GET "/services/$SVC/results/$RESULT/steps/$STEP/body" | jq -r .content
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
  the server, and the [key limit](../install/configuration.md#api-keys).
