---
description: "Tracedown is a self-hosted, open-source API monitoring platform: scripted multi-step HTTP probes, distributed agents, alerting, and full run history."
htmltitle: "Tracedown — Self-Hosted API & Synthetic Monitoring Platform"
---
# Tracedown

Tracedown is a **self-hosted API monitoring platform**. It runs automated
checks against your HTTP APIs on a schedule, records what happened in full
detail, and tells your team when something breaks or slows down.

A check can be as simple as *"is this endpoint returning 200?"* or as involved
as *"log in, fetch the order, verify the total changed, and warn me if it took
longer than usual"*. Probes are written in [Lace](https://lacelang.dev), a
purpose-built scripting language — not YAML with an `if` bolted on, and not a
general-purpose runtime you have to sandbox.

Want to click around before installing anything? A read-only
**[live demo](https://demo.tracedown.dev)** is running with real probes against
real endpoints — no signup, it logs you straight in.

## What a probe looks like

```lace
post("https://api.example.com/login", {
  body: json({ email: "$o.apiUser", password: "$o.apiPassword" })
})
.expect(status: 200)
.store({ "$$token": this.body.access_token })

get("https://api.example.com/orders", {
  headers: { Authorization: "Bearer $$token" }
})
.expect(status: 200)
.check(
  totalDelayMs: { value: 800 },
  ttfb:         { value: 300 }
)
```

`.expect()` fails the run; `.check()` records the problem and carries on.
`$o.apiUser` is a variable Tracedown injects — encrypted at rest, defined once
at the organization and referenced by scope from any script — and `$$token`
carries a captured value forward to the next call. Every call returns a full timing breakdown — DNS,
connect, TLS, time-to-first-byte, transfer — and every assertion records what it
actually saw, not just pass/fail.

## Capabilities

- **Scripted probes** — multi-step HTTP flows with chaining, captured values,
  cookie jars, and redirects. Assert on status, body (literal or JSON schema),
  headers, size, redirect hops, and each timing phase individually.
- **Scheduling** — cron-based, per service, with per-call timeouts and queue
  policies that decide what happens when a run overruns its own schedule.
- **Distributed agents** — probes execute on agents you deploy where you need
  them. Agents authenticate with mutual TLS against an internal CA and are
  health-checked continuously.
- **Variables with scope** — define at the organization, workspace, project,
  or service level and reference the scope you mean from any script. Secrets
  are encrypted at rest; scripts can write values back for the next run.
- **Notifications** — email and webhooks, fired on state transitions, with
  per-resource silences, personal quiet hours, and scheduled maintenance
  windows.
- **History and aggregation** — every run stored with its steps; hourly and
  daily rollups keep long windows cheap. Retention is yours to set.
- **Access control** — organizations, workspaces, projects, and services, with
  per-section permissions, groups, invites, API keys, and TOTP two-factor.
- **Metrics out** — a Prometheus scrape endpoint and Grafana integration, so
  Tracedown's data lands next to the rest of your observability stack.

## Where to start

<div class="grid cards" markdown>

-   :material-book-open-variant: **[User Manual](guide/index.md)**

    ---

    Concepts, creating services, writing probes, reading results, alerting.

-   :material-download: **[Installation](install/index.md)**

    ---

    Requirements, Docker quickstart, configuration reference, agents.

-   :material-server-network: **[Administration](admin/index.md)**

    ---

    Secrets, certificates, backups, retention, scaling, upgrades.

-   :material-code-braces: **[Lace Language](https://lacelang.dev)**

    ---

    The probe scripting language — grammar, assertions, extensions.

</div>
