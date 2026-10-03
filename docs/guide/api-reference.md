---
description: "Every endpoint of the Tracedown API v1 under /api/public/v1: method, path, parameters, request body, success response and the error codes particular to each."
---
# API Reference

!!! note "Tracedown 0.4.49 and later"
    This page describes the API as served from release 0.4.49 on. Release 0.4.48
    serves only `GET /key` under `/api/public/v1`.

Every endpoint of the [key-authenticated API](api.md), version 1 — 72 in all,
under `/api/public/v1` — plus the description at
`/api/openapi/public/v1.json`, which sits outside the namespace and needs no
key. The full request and response schemas are in that
[OpenAPI document](api.md#the-api-description); this page is the map.

## Conventions

- Paths are relative to `/api/public/v1`. Every request carries
  `Authorization: Bearer td_…`.
- Path ids are UUIDs; a malformed one is 400 `invalid_uuid`, with
  `details.field` naming which id. The only path parameters that are not ids
  are `resourceType` and `principalType`, on the access endpoints.
- Timestamps are ISO-8601 strings in UTC, except two numeric fields noted where
  they appear, which are epoch seconds.
- **Creates answer `200`** with the created resource. **Deletes answer `200`**
  with `{"ok": true}`. `POST /services/{id}/run` answers `202`; a few reads can
  answer `204`, noted per row.
- **Lists** take `page` (default 1) and `pageSize` (default 50, at most 100) and
  answer `{items, total, page, pageSize}` — written *Page of X* below. See
  [Paging](api.md#paging) for their order.
- **Write** endpoints — anything but `GET` and `HEAD` — need a write key; a read
  key gets 403 `api_key_read_only`. `HEAD` is answered on every `GET` endpoint.
- **Body:** lists the request fields; a body that is not JSON, has the wrong
  shape or fails a field's validation is 400 `invalid_request_body`, with
  `details.field` and `details.reason` when the gateway can name the field.
  **Errors:** lists only the codes particular to an endpoint. Every endpoint can
  also answer the [common ones](api.md#errors).

## Key

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/key` | Describes the calling key: name, prefix, access, expiry, and the organization and user it acts for. | `200` [ApiKeyInfo](#apikeyinfo) |

## Workspaces

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/workspaces` | Lists the workspaces the caller may see. | `200` Page of [Workspace](#workspace) |
| `POST` | `/workspaces` | Creates a workspace. Needs organization Workspaces Write.<br>Body: `name` (required, ≤ 128).<br>Errors: 403 `insufficient_permissions`; 409 `already_exists`. | `200` [Workspace](#workspace) |
| `GET` | `/workspaces/{id}` | Returns one workspace. | `200` [Workspace](#workspace) |
| `PATCH` | `/workspaces/{id}` | Renames a workspace.<br>Body: `name` (≤ 128). | `200` [Workspace](#workspace) |
| `DELETE` | `/workspaces/{id}` | Deletes a workspace with everything in it. | `200` `{"ok": true}` |
| `PATCH` | `/workspaces/{id}/services-toggle` | Switches every service in every project of the workspace on or off, in one transaction.<br>Body: `isActive` (required). | `200` [ToggleResult](#toggleresult) |

## Projects

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/projects` | Lists the projects of a workspace that the caller may see.<br>Query: `workspaceId` (**required**).<br>Errors: 400 `field_required` when `workspaceId` is missing. | `200` Page of [Project](#project) |
| `POST` | `/projects` | Creates a project in a workspace.<br>Body: `workspaceId` (required), `name` (required, ≤ 128).<br>Errors: 409 `already_exists`. | `200` [Project](#project) |
| `GET` | `/projects/{id}` | Returns one project. | `200` [Project](#project) |
| `PATCH` | `/projects/{id}` | Renames a project.<br>Body: `name` (≤ 128). | `200` [Project](#project) |
| `DELETE` | `/projects/{id}` | Deletes a project with its services. | `200` `{"ok": true}` |
| `PATCH` | `/projects/{id}/services-toggle` | Switches every service in the project on or off, in one transaction.<br>Body: `isActive` (required). | `200` [ToggleResult](#toggleresult) |

## Services

The script endpoints can refuse a script for what it targets. On a default
install (`TRUSTED_DOMAIN_MODE=false`) a domain the organization has not verified
is restricted:

| Code | Meaning |
|---|---|
| `unverified_domain_call_limit` | The script makes more than three calls while it targets an unverified domain. |
| `unverified_domain_includes` | The script uses an `includes` check while it targets an unverified domain. |
| `unverified_domain_interval` | The schedule is shorter than five minutes while the script targets an unverified domain. |

All three are 400. Verify the domain under **Settings → Domains**; see
[Domain trust](../install/configuration.md#domain-trust).

A script is also refused with 400 `blocked_probe_target` when it targets an
address no probe may reach (private, loopback, internal-only, or a non-HTTP
scheme). Verifying a domain does not change that.

A script that does not validate is refused with 400 `field_invalid` and
`details.field` = `script`. `details.errors` lists every problem the validator
reported (each with `code`, `callIndex`, `field` and `detail`), and
`details.reason` gives the first one's message. This holds wherever a script is
saved or checked: create, update, `/script` and `/toggle`.
Write and check it in the dashboard's editor, or with a Lace validator (see
[Writing Probes](writing-probes.md)), before sending it.

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/services` | Lists the services of a project that the caller may see.<br>Query: `projectId` (**required**).<br>Errors: 400 `field_required` when `projectId` is missing. | `200` Page of [Service](#service) |
| `POST` | `/services` | Creates a service in a project, switched off. A `script` in the body is saved as a first script save, which switches the service on unless `isActive` is `false`. `isActive: false` keeps it off. When the script or the enable is refused, the call leaves nothing behind — no service, no audit entries.<br>Body: `projectId` (required), `name` (required, ≤ 128), `label` (≤ 32), `schedule` (cron, ≤ 16, default `*/5 * * * *`), `saveResponseBodies` (default `true`), `script` (≤ 65536), `isActive`.<br>Errors: 409 `already_exists`; script errors as for `/script`; enabling errors as for `/toggle`. | `200` [Service](#service) |
| `GET` | `/services/{id}` | Returns one service. | `200` [Service](#service) |
| `PATCH` | `/services/{id}` | Updates a service's configuration; fields left out are unchanged. A `script` here needs `version`.<br>Body, all optional: `name` (≤ 128), `label` (≤ 32), `schedule` (≤ 16), `probeMode` (`consecutive`, `simultaneous`, `random`), `queuePolicy` (`skip`, `enqueue_once`), `serviceWindow` (≤ 256), `saveResponseBodies`, `script` (≤ 65536), `version`.<br>Errors: 400 `field_required` (a `script` without `version`), `field_invalid` (a malformed `serviceWindow`), `unverified_domain_interval`; 409 `version_conflict`; script errors as for `/script`. | `200` [Service](#service) |
| `DELETE` | `/services/{id}` | Deletes a service. | `200` `{"ok": true}` |
| `PATCH` | `/services/{id}/script` | Replaces the Lace script. Validated before it is saved; the service's `version` goes up by one. The first save of a service that has never been saved (still at `version` 1) switches it on; if that enable is refused, the script is still saved and the service stays off.<br>Body: `script` (required, ≤ 65536), `version` (required — the version being replaced).<br>Errors: 400 `field_invalid` (the script does not validate: `details.field` = `script`, with `details.errors` and `details.reason`), `blocked_probe_target`, `unverified_domain_call_limit`, `unverified_domain_includes`, `unverified_domain_interval`; 409 `version_conflict`. | `200` [Service](#service) |
| `GET` | `/services/{id}/snapshot` | The service and its most recent runs, in one read. | `200` [ServiceSnapshot](#servicesnapshot) |
| `PATCH` | `/services/{id}/toggle` | Switches the service on or off. Switching on needs a valid script.<br>Body: `isActive` (required).<br>Errors: 400 `field_required` (no script), `field_invalid` (the script does not validate, with `details.errors` and `details.reason`). | `200` [Service](#service) |
| `POST` | `/services/{id}/run` | Asks for one run now, outside the schedule. The result appears under `/results` when it lands — see [Running a service now](api.md#running-a-service-now).<br>Errors: 409 `service_inactive`, `script_missing`. | `202` `{"ok": true, "requestedAt": "…"}` |
| `GET` | `/services/{id}/agents` | The agent slugs the service may run on. An empty list means any agent. | `200` list of slugs |
| `PUT` | `/services/{id}/agents` | Replaces the agents the service may run on. An empty list means any agent.<br>Body: `slugs` (required, list).<br>Errors: 400 `field_invalid` with `details.unknown` listing slugs that name no agent the caller can use — unknown, inactive or not visible to them. | `200` list of slugs |

## Agents

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/agents` | Lists the active probe agents the caller can name in `PUT /services/{id}/agents`, by slug and label, ordered by slug — nothing about where they are or how they are doing. | `200` list of [Agent](#agent) |

## Variables

The same endpoints exist at four scopes:

| Scope | `{scope}` prefix | Permission it needs |
|---|---|---|
| Organization | *(empty)* — so `/variables` | Organization Settings Read to list, Write to change |
| Workspace | `/workspaces/{id}` | Read on the workspace to list, write to change |
| Project | `/projects/{id}` | Read on the project to list, write to change |
| Service | `/services/{id}` | Read on the service to list, write to change |

In the paths below, `{scope}` is one of the prefixes above. Values come back
masked; see [Variables](api.md#variables).

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `{scope}/variables` | Lists the scope's variables.<br>Errors: 403 `insufficient_permissions` (organization scope). | `200` Page of [Variable](#variable) |
| `POST` | `{scope}/variables` | Creates a variable.<br>Body: `key` (required, ≤ 64), `value` (required, ≤ 4096), `type` (`variable` default, `secret`, `metric`).<br>Errors: 400 `variable_limit_reached`, `reserved_key` (not at organization scope); 403 `insufficient_permissions` (organization scope); 409 `already_exists`. | `200` [Variable](#variable) |
| `PATCH` | `{scope}/variables/{varId}` | Replaces a variable's value.<br>Body: `value` (required, ≤ 4096).<br>Errors: 400 `readonly_variable` (not at organization scope); 403 `insufficient_permissions` (organization scope). | `200` [Variable](#variable) |
| `DELETE` | `{scope}/variables/{varId}` | Deletes a variable.<br>Errors: 400 `system_variable` (not at organization scope); 403 `insufficient_permissions` (organization scope). | `200` `{"ok": true}` |
| `GET` | `{scope}/variables/hierarchy` | Every variable the resource sees, from its own scope up to the organization's, with each scope's computed, read-only variables. Workspace, project and service scope only: the organization has nothing above it. | `200` [VariableHierarchy](#variablehierarchy) |

## Results

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/services/{id}/results` | Lists the service's runs, newest first.<br>Query: `since` (ISO-8601: runs started at or after it). | `200` Page of [ResultSummary](#resultsummary) |
| `GET` | `/services/{id}/results/{resultId}` | Returns one run with all of its steps. | `200` [Result](#result) |
| `GET` | `/services/{id}/results/{resultId}/steps/{stepId}/body` | The response body the step stored, inline. See [Step bodies](api.md#step-bodies) and the answers below. | `200` [StepBody](#stepbody); `204` |

### Step body answers

| Status | Code | Meaning |
|---|---|---|
| 200 | — | The body, as [StepBody](#stepbody). |
| 204 | — | The step has no stored body (`hasBody` is false): none was saved, or retention or a forgotten store has since cleared it. `bodyNotStoredReason` on the step says which. |
| 410 | `body_gone` | The step still records a body and the object is not there — deleted from its storage outside Tracedown, or no longer inside the store it was recorded in. Final: there is nothing to retry. |
| 413 | `body_too_large` | The stored body is over the 4 MiB inline cap. `details.maxBytes` says what the cap is. |
| 503 | `body_store_unavailable` | The storage holding the body did not answer within 15 seconds, or no read slot came free within 10 seconds because the gateway was already reading as many bodies as it allows at once. Answers carry `Retry-After: 10`. The body is probably still there; try again after that. |

`410` and `503` are deliberately different answers: the first says the body is
gone, the second says it could not be reached just now. See
[Body Stores](../admin/body-stores.md#when-a-body-cannot-be-read) for the
operator's side.

## Metrics

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/services/{id}/metrics` | Current counters and state of the service. | `200` [ServiceMetrics](#servicemetrics); `204` while it has none |
| `GET` | `/services/{id}/metrics/history` | Hourly buckets for the service.<br>Query: `hours` (default 24, 1–168). | `200` list of [HourlyBucket](#hourlybucket) |
| `GET` | `/services/{id}/metrics/statistics` | Uptime, error rate, latency trend and per-endpoint breakdown over a window.<br>Query: `window`: `24h` (default), `7d`, `30d`, `90d`. | `200` [Statistics](#statistics) |
| `GET` | `/services/{id}/metrics/statistics/endpoint-series` | The window per endpoint over time, on the same buckets.<br>Query: `window`. | `200` [EndpointSeries](#endpointseries) |
| `GET` | `/services/{id}/metrics/statistics/assertions` | The window's most-failing assertions, with how far back it actually read (`since`, `truncated`).<br>Query: `window`. | `200` [AssertionFailures](#assertionfailures) |
| `GET` | `/services/{id}/metrics/statistics/failure-heatmap` | Failed runs by UTC hour of day and ISO weekday.<br>Query: `days` (default 90, 1–365). | `200` [FailureHeatmap](#failureheatmap) |
| `GET` | `/projects/{id}/metrics` | Current counters and state across the project's services the caller may see. | `200` [ServiceMetrics](#servicemetrics) with `serviceCount`; `204` when there is no data |
| `GET` | `/projects/{id}/metrics/history` | Hourly buckets across those services.<br>Query: `hours` (default 24, 1–168). | `200` list of [HourlyBucket](#hourlybucket) |
| `GET` | `/workspaces/{id}/metrics` | Current counters and state across the workspace's projects the caller may see. | `200` [ServiceMetrics](#servicemetrics) with `projectCount` and `serviceCount`; `204` when there is no data |
| `GET` | `/workspaces/{id}/metrics/history` | Hourly buckets across those projects.<br>Query: `hours` (default 24, 1–168). | `200` list of [HourlyBucket](#hourlybucket) |

An out-of-range `hours`, `days` or `window` is 400 `field_invalid` naming the
parameter.

## Silences

These are the **calling user's own** notification silences — what the bell
icons in the dashboard set — not an organization-wide mute. See
[Silences & Quiet Hours](silences.md).

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/silences` | Lists the caller's silences. | `200` Page of [Silence](#silence) |
| `POST` | `/silences` | Creates a silence for the caller.<br>Body: `channel` (required: `email`, `all` or `quiet-hours`), at most one of `workspaceId`, `projectId`, `serviceId`, `config` (JSON as a string), `quietHours` (`RRULE[/minutes[/timezone]]`).<br>Errors: 400 `field_invalid` (channel `webhook`, more than one resource, malformed quiet hours or `config`); other unknown channels are `invalid_request_body`. | `200` [Silence](#silence) |
| `GET` | `/silences/{id}` | Returns one of the caller's silences. | `200` [Silence](#silence) |
| `PATCH` | `/silences/{id}` | Changes a silence's channel, configuration or quiet hours.<br>Body, all optional: `channel`, `config`, `quietHours`.<br>Errors: 400 `field_invalid`. | `200` [Silence](#silence) |
| `DELETE` | `/silences/{id}` | Removes one of the caller's silences. | `200` `{"ok": true}` |

## Access

Who may see or change a workspace, project or service. `resourceType` is
`workspace`, `project` or `service`; a principal is a `user` (by user id, as
the [members](#directory) list gives it) or a `group`. Every call here needs
write on the resource. See
[Resource grants](users-and-permissions.md#resource-grants).

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/access/{resourceType}/{resourceId}` | Lists the users and groups granted access to the resource, and at which level.<br>Errors: 400 `field_invalid` (resource type). | `200` list of [AccessEntry](#accessentry) |
| `PUT` | `/access/{resourceType}/{resourceId}` | Grants a user or group access, or changes the level of an existing grant.<br>Body: `principalType` (`user` or `group`), `principalId`, `permissions` (`1` read, `2` write).<br>Errors: 400 `field_invalid` (resource type). | `200` `{"ok": true}` |
| `DELETE` | `/access/{resourceType}/{resourceId}/{principalType}/{principalId}` | Removes a user's or group's grant on the resource.<br>Errors: 400 `field_invalid`. | `200` `{"ok": true}` |

## Directory

Read-only: where a client finds the ids it grants access to. Both need
organization Users Read.

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/members` | Lists the organization's members, disabled ones included (pending invitations are not members).<br>Errors: 403 `insufficient_permissions`. | `200` Page of [Member](#member) |
| `GET` | `/groups` | Lists the organization's groups, with member counts.<br>Errors: 403 `insufficient_permissions`. | `200` Page of [Group](#group) |

## Webhooks

Attaching the organization's existing webhooks to a workspace, project or
service. Webhooks themselves are created and edited in the dashboard; here they
are read-only, and redacted. Listing webhooks needs organization Webhooks Read.
Listing a resource's bindings also needs read on that resource; creating one
needs Webhooks Write and write on the resource — a resource the caller cannot
read or write is 404. Changing or removing a binding needs Webhooks Write.

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/webhooks` | Lists the organization's webhooks: id, name, label, method and creation time — never the URL, headers, body or configuration.<br>Errors: 403 `insufficient_permissions`. | `200` Page of [Webhook](#webhook) |
| `GET` | `/webhooks/bindings` | Lists the webhooks bound to a resource.<br>Query: `resourceType` (**required**: `workspace`, `project`, `service`), `resourceId` (**required**).<br>Errors: 400 `field_required` naming the missing parameter, `field_invalid` for an unknown `resourceType`; 403 `insufficient_permissions`. | `200` Page of [WebhookBinding](#webhookbinding) |
| `POST` | `/webhooks/bindings` | Binds a webhook to a resource.<br>Query: `resourceType`, `resourceId` (both **required**).<br>Body: `webhookId` (required), `enabled` (default `true`).<br>Errors: 400 `field_required`, `field_invalid` for an unknown `resourceType`; 403 `insufficient_permissions`; 409 `binding_exists`. | `200` [WebhookBinding](#webhookbinding) |
| `PATCH` | `/webhooks/bindings/{id}` | Pauses or resumes a binding.<br>Body: `enabled` (required).<br>Errors: 400 `field_required` without `enabled`; 403 `insufficient_permissions`. | `200` [WebhookBinding](#webhookbinding) |
| `DELETE` | `/webhooks/bindings/{id}` | Removes a binding. The webhook itself stays.<br>Errors: 403 `insufficient_permissions`. | `200` `{"ok": true}` |

## The API description

| Method | Path | What it does | Answers |
|---|---|---|---|
| `GET` | `/api/openapi/public/v1.json` | The OpenAPI 3.1 description of everything above. No key; metered per address. Note the path: it is **not** under `/api/public/v1`. | `200` OpenAPI document |

## Response shapes

The fields each response carries, in brief. Types, nullability and the nested
objects in full are in the OpenAPI document.

### ApiKeyInfo

`id`, `name`, `prefix`, `access` (`read` or `write`), `expiresAt` (null when it
never expires), `organization` {`id`, `name`}, `user` {`id`, `email`}.

### Workspace

`id`, `name`, `createdAt`.

### Project

`id`, `workspaceId`, `name`, `createdAt`, `serviceCount`, and `metrics` (a
[ServiceMetrics](#servicemetrics) object, when there is data).

### Service

`id`, `projectId`, `name`, `label`, `script`, `schedule`, `probeMode`,
`queuePolicy`, `serviceWindow`, `saveResponseBodies`, `isActive`, `lastStatus`,
`lastStatusSince`, `version` (send it back with a script change),
`createdAt`, `unverifiedTargets`, and when available `metrics` and
`lastFailure` (the failed assertions of the latest failing run).

### ServiceSnapshot

`service` (a [Service](#service)) and `recentProbes`: a list of {`status`,
`avgResponseMs`, `callCount`, `failedCalls`, `timestamp`} — `timestamp` in
**epoch seconds**.

### ToggleResult

`matched`, `changed`, `unchanged`, `skipped` (a list of {`serviceId`, `name`,
`reason`}), `skippedTotal`, `skippedByReason`.

### Agent

`slug`, `label`.

### Variable

`id`, `key`, `value`, `type` (`variable`, `secret` or `metric`), `masked`
(true when `value` is the mask rather than the value — see
[Variables](api.md#variables)), `systemType` (set on the
variables Tracedown seeds itself), `createdAt`, `updatedAt`.

### VariableHierarchy

`scopes`: one entry per scope from the resource up to the organization, each
with `scope`, `prefix` (how a script addresses it, such as `$w.`),
`resourceId`, `resourceName`, `editable`, `variables` (a list of
[Variable](#variable)) and `locked` (that scope's computed, read-only
variables such as `$s.name`, each {`key`, `value`, `description`}).

### ResultSummary

`id`, `status`, `runDurationMs`, `totalResponseMs`, `startedAt`, `agentSlug`.

### Result

`id`, `serviceId`, `status`, `runDurationMs`, `startedAt`, `probeAgentId`,
`agentSlug`, `rawResult`, and `steps`. Each step has `id`, `stepNum`,
`requestUrl`, `statusCode`, `responseTimeMs`, the phase timings (`dnsMs`,
`connectMs`, `tlsMs`, `ttfbMs`, `transferMs`), `responseSizeBytes`, `error`,
`assertionResults`, `headers`, `hasBody` and `bodyNotStoredReason`.

`rawResult` follows the Lace ProbeResult format, with storage locators blanked
(`calls[].response.bodyPath` and keys like it are `null`); a step's body is read
through `hasBody` and the [body endpoint](#results), never from `rawResult`.

### StepBody

`content`, `contentType` (null when none was recorded or it is not one the
gateway repeats back), `encoding` (`null` for
text as it is, `"base64"` otherwise). See [Step bodies](api.md#step-bodies).

### ServiceMetrics

`counters` {`probesTotal`, `probesSuccess`, `probesFailure`, `probesTimeout`},
`state` {`lastStatus`, `lastConsecutive`, `lastResponseMs`, `lastRunAt` — in
**epoch seconds**}, `percentiles` {`p50`, `p95`, `p99`}, and on project and
workspace metrics `serviceCount` and `projectCount`.

### HourlyBucket

`hour`, `total`, `success`, `failure`, `timeout`, `sumMs`, `callCount`.

### Statistics

`window`, `bucketType`, `overall` (buckets of {`bucketStart`, `p50Ms`,
`p95Ms`, `p99Ms`, `uptimePct`, `errorRatePct`, `probeCount`}), `regions` (the
same buckets per agent), `endpoints` (per endpoint: calls, status-code counts,
phase timings against the previous window, average size), and
`endpointsTruncated`.

### EndpointSeries

`window`, `bucketType`, `buckets`, `all` (every endpoint together),
`endpoints` (per endpoint: `key`, `method`, `template`, `points`), and
`endpointsTruncated`.

### AssertionFailures

`window`, `since`, `until`, `truncated`, and `assertions`: per assertion, the
endpoint, what it checked, `failures`, `evaluations`, `failureRatePct` and
`lastFailedAt`.

### FailureHeatmap

`days`, `timezone`, `since`, `until`, `coveredFrom`, `coveredTo`, `totalRuns`,
`totalFailedRuns`, and `cells` of {`weekday`, `hour`, `runs`, `failedRuns`}.

### Silence

`id`, `orgUserId`, `workspaceId`, `projectId`, `serviceId` (at most one set),
`channel`, `config`, `quietHours`, `resourceName`.

### AccessEntry

`principalType`, `principalId`, `name`, `email` (for users), `permissions`
(`1` read, `2` write).

### Member

`userId`, `displayName`, `email`, `isActive`.

### Group

`id`, `name`, `memberCount`.

### Webhook

`id`, `name`, `label`, `method`, `createdAt`.

### WebhookBinding

`id`, `webhookId`, `webhookName`, `enabled`, `createdAt`.
