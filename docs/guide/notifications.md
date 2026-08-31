---
description: "Tracedown has no alert-rule builder - your probe script emits notification events. How they are grouped, templated and delivered over email and webhooks."
---
# Notifications

**Alerts are authored in the probe script, not in a UI rule builder.** There is
no page in Tracedown where you define alert conditions. Nothing to click, no
threshold form, no "notify when" dropdown. If you went looking for one, this
page explains why you did not find it.

The script that asserts something is the only thing that knows what it asserted.
A probe that logs in, fetches an order and checks the total against a stored
value has a notion of "wrong" that no generic rule builder could express, and
which would in any case have to be kept in sync with the script by hand. So the
decision lives where the knowledge lives: your Lace script emits notification
events, and Tracedown delivers them.

What Tracedown provides is everything downstream of that decision — grouping,
rendering, recipients, channels, and the suppression rules that stop a bad night
turning into a thousand emails.

## How a notification comes to exist

1. Your probe script runs and an assertion fails, or a call times out.
2. Lace's `laceNotifications` extension emits a notification event into the
   result under `actions.notifications`.
3. Tracedown reads those events, groups them by call index and trigger, renders
   the text, and delivers it.

The trigger tells Tracedown what kind of failure it was — `expect`, `check`,
`timeout`, `error`, and so on — and defaults to `expect`. Grouping by call index
and trigger means one broken call that trips several assertions produces one
coherent message about that call, rather than a separate alert per assertion.

Two further layers of suppression sit on the platform side, independent of
anything the script does. Every event from one run is coalesced into a single
message per channel — one email per service per run, however many assertions
tripped. And each recipient has a per-service cooldown: once you have been
emailed about a service, further email about that service is suppressed for
five minutes. The cooldown applies per person and per channel, drops the mail
silently, and exists so that a service failing on a one-minute schedule pages
you once, not sixty times an hour.

### Recovery

When a service that was failing succeeds again, Tracedown emits a `recovered`
notification on its own — it is composed by the platform, not by your script.
The default message names the service and how long it was down
(`${downtime}`), and the email subject switches to a recovery subject. You do
not have to write anything for this to happen.

### Emitting notifications from a script

Notifications are enabled by the `laceNotifications` extension. When it is
active, a scope's `options` block accepts a `notification` field:

```lace
get("https://api.example.com/orders")
.expect(
  status: {
    value: 200,
    options: {
      notification: template("unexpected_status_alert")
    }
  }
)
.check(totalDelayMs: { value: 1000 })
```

If you emit nothing custom, the extension still emits a default notification
carrying the failure's details, so a failing assertion alerts without any extra
work. The `notification` option is for when you want to choose the wording, or
select a different message depending on how the assertion failed.

The extension also suppresses a notification when the same scope failed on the
previous run, which is what stops a persistently broken endpoint from mailing
you every minute until you fix it. See [Writing Probes](writing-probes.md), and
the `laceNotifications` documentation in the Lace manual, for the full option
set.

## Channels

Tracedown delivers on two channels: **email** and **webhook**.

They differ in more than transport. Email is resolved to individual recipients
and is therefore subject to each person's [silences and quiet
hours](silences.md). Webhooks are bound to resources rather than people, so they
fire regardless of anyone's personal settings — which is what you want for a
paging integration or a chat channel, and worth knowing before you assume quiet
hours will keep a webhook quiet overnight.

## Notification templates

Templates live under **Infrastructure -> Notifications**. Each has a name and a
body of text containing `${var}` placeholders that are resolved at dispatch.

Commonly used placeholders:

| Placeholder | Resolves to |
|---|---|
| `${s.name}` | The service name. |
| `${p.name}` | The project name. |
| `${w.name}` | The workspace name. |
| `${url}` | The URL of the call that triggered the notification. |
| `${status}` | The probe run's **outcome** (`success`, `failed`, …) — not the HTTP status code. For a status assertion, the HTTP codes are in `${expected}` and `${actual}`. |
| `${ms}` | The call's response time in milliseconds. |
| `${expected}` | The value the assertion expected. |
| `${actual}` | The value it actually saw. |
| `${conditions}` | A rendered summary of the failed conditions. |
| `${downtime}` | How long the service was down — recovery notifications only. |
| `${text}` | The notification text. |

A script selects a template by name:

```lace
get("https://api.example.com/orders")
.expect(
  status: {
    value: 200,
    options: {
      notification: template("orders_down")
    }
  }
)
```

!!! warning "A template must be bound to a project to be usable"
    Templates are bound to **projects**. A script can only reference a template
    that is bound to the project its service lives in — an unbound template is
    invisible to every script, and referencing it falls back to the default
    message rather than raising an error. This is a real and easily missed
    gotcha: the template exists, the name is spelled correctly, and the alert
    still comes out generic.

    The template list can be filtered by project, or to unbound templates only.
    That second filter is the fastest way to find templates you created and
    never wired up.

## Webhooks

Webhooks are configured under **Infrastructure -> Webhooks**.

| Field | Notes |
|---|---|
| Name | Identifies the webhook. |
| Label | Optional. |
| Method | One of `GET`, `POST`, `PUT`, `PATCH`. `GET` sends no body. |
| Retries | Total delivery attempts, 1–10. Default `1` — no retry. Only network failures and 5xx responses are retried, with exponential backoff; a 4xx is never retried. |
| URL | The delivery target. Must be `https`, and may embed organization variables. |
| Body template | The JSON payload to send. Validated as JSON. |
| Delivery config | JSON for auth headers and query parameters. |

The URL is checked against internal and private address ranges when the
webhook is saved and again at every delivery, and redirects are never followed
— a webhook cannot be pointed at the platform's own network.

### Keeping secrets out of the URL

The URL may reference organization variables — `$o.name`, for example — which
are resolved at delivery time rather than stored expanded. The same resolution
applies to header and query values in the delivery config.

This is deliberate. Many third-party endpoints carry the credential in the path
itself, and storing that URL verbatim would put a live secret in a plainly
readable configuration field. Referencing a variable instead means the stored
URL holds a placeholder and the secret stays in the variable system, where it is
encrypted at rest. See [Variables](variables.md).

### The body template must carry `${text}`

The body template is validated as JSON, and for methods that send a body it must
contain `${text}` — the rendered notification text. Without it the request
would deliver reliably and say nothing, a failure mode you would only discover
during an incident. The editor blocks saving the webhook rather than let you
find out then. (The API itself enforces only that the body is valid JSON — a
webhook created programmatically without `${text}` is accepted, and delivers
messages that say nothing.)

### Bindings

A webhook is bound per **workspace**, **project** or **service**, and each
binding has its own enable/pause toggle. One webhook can therefore serve a whole
workspace while being paused for the one noisy service in it, without
duplicating the configuration.

## Who gets notified

This rule is short but not obvious, and it surprises people:

!!! info "Recipients are grant holders"
    Notifications go to the active organization users who hold a **grant** —
    read or write, directly or through a group — on the service, or on its
    parent project or workspace. An organization-wide `workspaces` permission is
    **not** enough.

The distinction is between administrative reach and stated interest. An
organization admin can open every workspace, but it does not follow that they
want an alert from every service in the company at 04:00. If eligibility tracked
broad permissions, granting someone administrative access would silently
subscribe them to everything, and the only way out would be to unsubscribe from
each service by hand.

So eligibility follows explicit grants only. To receive alerts for a service,
hold a grant on it or on something above it. This is also why the silence bell
appears only for grant holders: someone with no grant has no notifications to
silence. See [Users & Permissions](users-and-permissions.md) and
[Silences & Quiet Hours](silences.md).

## System alerts

Separately from your probes, the platform raises alerts about its own health.
These are not authored in any script — Tracedown emits them itself.

| Type | Meaning |
|---|---|
| `dispatch_capacity` | Probes are being skipped; the platform is over its probing capacity. |
| `no_eligible_agent` | Probes are being skipped because no healthy agent was available to run them. |
| `agent_dispatch_failed` | The agents looked healthy, and every one of them refused the probe or could not be reached. |
| `agent_down` | A probe agent is not responding to health checks. |
| `agent_degraded` | A probe agent is responding, but its health check is slow. |
| `health_token_unavailable` | Agent health checks cannot complete, so agent statuses are being held where they are. |

These matter because they describe gaps in your monitoring rather than problems
with your APIs. A skipped probe is a check that never ran; see
[Reading Results](results.md).

Banners in the dashboard show only the latest episode of each type, so a
flapping agent does not paper the screen. The full record lives under **Settings
-> Warning log**, with severity, type, subject, first seen and last seen. First
seen and last seen together tell you whether you are looking at one long episode
or a repeating one, which is usually the difference between a saturated agent
and an intermittent network path.

## Silences, quiet hours and maintenance windows

Three mechanisms stop notifications, and they are not interchangeable:

- A [maintenance window](maintenance-windows.md) stops **probing** entirely. No
  probes run, so no results are recorded and nothing can alert. Use it when the
  target is legitimately down and you do not want the outage in your history.
- A [silence](silences.md) stops **notifications** while probing continues.
  Results are still recorded, success rates stay honest, and only your mail
  stops.
- [Quiet hours](silences.md#quiet-hours) stop notifications to **you** during a
  recurring time window, regardless of which resource they concern. Probing and
  everyone else's mail are untouched.

The choice comes down to a question worth asking before every planned
deployment: do you want to know what happened, or not? A maintenance window
means the answer is unrecorded. A silence means you can read it back afterwards
in peace.
