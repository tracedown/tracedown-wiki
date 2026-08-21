---
description: "Read Tracedown probe results: success-rate stats, service metrics, run history, per-call DNS, TLS and TTFB timings, assertion detail and live WebSocket updates."
---
# Reading Results

Every probe run is stored whole: each call, each timing phase, and every
assertion together with the value it actually saw. This page walks from the
highest-level number — a success rate on a workspace header — down to the
individual assertion that failed, and explains which view answers which
question.

The guiding principle is that you should not have to re-run a probe to find out
why it failed. The run already recorded it.

## Header stats

Workspace and project views open with a stats header covering the last 24 hours
of history, with a window selector offering **24h**, **12h**, **6h** and **2h**.
The selector narrows the same fetched history rather than requesting a
different range, so switching between windows is instant.

| Stat | Meaning |
|---|---|
| Success rate | Share of probes in the window that succeeded. Colour-graded. |
| Avg response / call | Mean response time per individual call, not per probe. |
| Probes | Number of probes run in the window. |
| Failures | Number of probes that failed in the window. |
| Projects / Services | Static counts of what the resource contains. |

Success rate is colour-graded against thresholds rather than printed as plain
text, so a wall of green reads as healthy at a glance and anything else draws
the eye. The defaults treat 99% and above as healthy and 95% and above as a
warning.

!!! note "Avg response / call, not per probe"
    A probe with five calls contributes five samples to this average. This is
    deliberate: a multi-step login-then-fetch flow would otherwise look slower
    than a single-call health check purely because it does more work.

The chart beneath the stats shows stacked bars of successes and failures —
failures include timeouts — with an average-response line drawn against a
right-hand axis. Two axes means you can see a latency climb that has not yet
turned into failures, which is usually the earliest warning you get.

Buckets are keyed hourly in UTC by the server and converted to your local time
for display, so the chart lines up with your working day while remaining
comparable across a team spread over timezones.

## Service metrics

A service shows a metrics summary:

| Stat | Meaning |
|---|---|
| Total probes | Lifetime count of probes run for this service. |
| Success rate | Share that succeeded, colour-graded as above. |
| Avg response / call | Mean response time per call. |
| Last status | Outcome of the most recent probe. |

Response-time **percentiles** — p50, p95 and p99 — live on the service's
**Statistics** tab, charted over windows from 24 hours to 90 days. Percentiles
matter more than the average: an average hides the tail — a service can
average 120 ms while one request in twenty takes two seconds. p95 and p99 are
where that shows up, and they are usually what your users actually experience
when they complain that something is slow.

The recent-probes chart plots an average-response line over the last 10 probes,
with each point coloured by that probe's status and failed-call counts drawn as
bars on a second axis. It is a quick read on whether a failure was a blip or the
end of a visible trend.

## Probe history

Once a service has metrics, a **Probe history** tab appears, listing runs 12 per
page next to a detail pane. Each row carries a status dot, the status, the total
response time, a relative timestamp, and the slug of the agent that ran it.

The agent slug is worth attention. If one agent's runs fail while another's
succeed against the same service, you are looking at a network path or agent
problem, not a broken API.

### Skipped probes

A probe with a status of `skipped` shows a banner explaining what happened.

| Reason | What you see |
|---|---|
| `dispatch_queue_full`, `dispatch_backlog` | The scheduler's dispatch queue was full — the platform is over its probing capacity. |
| Anything else | The probe was never dispatched to an agent. |

!!! warning "Skipped is not the same as failed"
    A skipped probe means Tracedown could not run the check. It says nothing
    about the target, which may have been perfectly healthy at the time.
    Treating skips as failures will make your success rate lie to you; treating
    them as successes will hide a monitoring outage. They are a signal about
    your Tracedown deployment — capacity, agents, scheduling — and they are
    reported separately for that reason. See
    [Notifications](notifications.md) for the capacity alerts the platform
    raises on your behalf.

## Result detail

Selecting a result opens two tabs.

=== "Calls"

    One row per step of the probe, each showing its step number, the request
    URL, the status code and the response time. Expanding a row reveals the
    step detail described below.

=== "Raw result"

    A JSON viewer showing the raw result the executor returned, exactly as it
    was stored. This is the escape hatch: when the structured views do not
    explain something, the unprocessed record will.

### Step detail

Each step carries a timing breakdown across five phases:

| Phase | Covers |
|---|---|
| DNS | Resolving the hostname. |
| Connect | Establishing the TCP connection. |
| TLS | Completing the TLS handshake. |
| TTFB | Waiting for the first byte of the response. |
| Transfer | Receiving the rest of the body. |

The UI notes that phases may overlap and the sum may exceed the total response
time. Do not treat these as a partition of the total — treat them as a way to
locate a problem. A slow DNS phase and a slow TTFB have entirely different
causes and entirely different fixes, which is the whole reason the phases are
recorded separately rather than rolled into one number. You can assert on each
of them individually; see [Writing Probes](writing-probes.md).

Alongside the timings, a step shows its response size in KB, any error, and its
assertions.

#### Assertions

Each assertion records its scope, its operator, the expected value, the actual
value, and whether it passed.

That the **actual** value is recorded is the point worth dwelling on. Most
monitoring tells you an assertion failed and leaves you to reproduce it by hand,
by which time the condition has often cleared. Here the run already tells you
that you expected `200` and got `503`, or that you allowed 1000 ms and it took
1450 ms. A failure at 03:00 is diagnosable at 09:00 from the record alone.

```lace
get("https://api.example.com/orders")
.expect(status: 200)
.check(totalDelayMs: { value: 1000 })
```

If this returns 503 in 1450 ms, the history records both facts — the status
mismatch and how far over the threshold the timing was — not merely that the
probe went red.

#### Headers and body

Response headers are shown as collapsible JSON. The response body is fetched on
demand rather than loaded with the result, since bodies are much larger than the
rest of a run and you rarely need them.

When a body is not available the UI says one of:

- **Body not stored: {reason}** — saving was on, but this body was not kept.
- **Body saving not enabled** — body saving is off for this probe.

Body saving is off by default. It is a deliberate default rather than an
oversight: bodies are the most expensive thing to keep and the most likely to
contain data you would rather not store.

## Live updates

The dashboard subscribes to live channels for the workspace, project, service
and agent health, updating in place on events such as probe completion, metric
deltas and variable changes. If the WebSocket is unavailable it falls back to
polling, so the views stay current either way — just less promptly.

!!! note "Expect a small numeric wobble"
    Counts patched from live events are approximations. Some events do not carry
    every field the summary displays, so the UI estimates and lets the next full
    fetch correct the drift. A figure that shifts slightly when a snapshot lands
    is the correction working, not a bug. Trust the fetched numbers; treat the
    live ones as a fast-moving preview.

## Usage

A **Usage** tab is available on services, projects, workspaces and the
organization, covering periods of **2h**, **24h**, **3d** and **7d**. It reports
**Requests**, **Ingress** and **Egress** — the request count and the measured
network volume in each direction.

Usage is summed from retained data, so it can only reach as far back as your
retention period allows. When the server returns a shorter window than you
asked for, the tab says:

> Window capped to {hours}h by the retention period.

The hours shown are what you actually got, not what you requested. If you see
this on the 7d period, retention — not the usage view — is what to change.

## Metrics for Prometheus and Grafana

Tracedown can expose probe metrics on a Prometheus scrape endpoint. The
integration is configured **per project**, in the project's **Settings** tab —
not per organization and not per service — so each project's metrics can go to
whichever dashboard owns that project.

To set it up:

1. Open the project's **Settings** tab and choose **Enable integration**.
2. Copy the bearer token shown. It is displayed once and not shown again.
3. Copy the **Scrape endpoint** URL.
4. Point a Prometheus data source at that URL, configured to send the token as
   an `Authorization: Bearer <token>` header.

Afterwards the integration can be paused, its token regenerated, or the whole
thing deleted. Pausing and regenerating are separate actions for a reason:
regenerating rotates a leaked token while leaving scraping configured, whereas
pausing stops scraping without invalidating anything.

Under **Service scope** you can restrict the endpoint to a subset of the
project's services. Leaving it empty exports all services, which is the default.
Scoping is useful when a dashboard only cares about a handful of critical
services and you would rather not ship the rest across.

!!! tip "Metrics complement history, they do not replace it"
    The scrape endpoint is for dashboards and long-range trends. Probe history
    remains the place to find out what a specific failing run actually saw —
    Prometheus stores your numbers, not your assertions.
