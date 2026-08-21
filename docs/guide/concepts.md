---
description: "The ideas behind Tracedown: the organization, workspace, project and service hierarchy, probes as scripts, hard and soft assertions, runs, calls and agents."
---
# Concepts

Six ideas carry the whole product. Everything else in this manual assumes them.

## The hierarchy

```
organization
└── workspace
    └── project
        └── service   ← the thing that gets probed
```

An **organization** is the tenant: users, groups, permissions, webhooks,
notification templates, and the audit log all belong to it. Probe agents are
the one exception — they belong to the installation as a whole and are managed
by members holding Settings write.

A **workspace** groups projects. A **project** groups services. A **service** is
a single monitored thing — one probe script, one schedule.

The nesting is not bureaucracy. It exists so that two things reach downward:

- **Variables** — define a credential or a base URL once at the level where it
  is true, and every service beneath can reference it by scope
  (`$o.apiToken`, `$p.baseUrl`). See [Variables](variables.md).
- **Access** — grant a team the workspace they own, and they get everything
  inside it. See [Users & Permissions](users-and-permissions.md).

If you find yourself pasting the same value into ten services, you have found
the level it should have been defined at.

## A probe is a script, not a checkbox

A service's probe is a [Lace](https://lacelang.dev) script. Lace is a language
built for exactly this job: describe HTTP calls, assert things about the
responses, and carry values between them.

This is the design decision the rest of the product follows from. A checkbox UI
can express "is it 200?". It cannot express "log in, read the order, confirm the
total changed, and complain if the handshake got slower". A script can, and it
stays readable while doing it.

## Hard and soft assertions

Every check is one of two kinds, and the difference matters more than it looks:

| Method | On failure | Use it for |
|---|---|---|
| `.expect()` | Fails the run and stops the script | Correctness — the thing is wrong |
| `.check()` | Records the failure and continues | Health — the thing is degrading |

A response that returns 500 is broken; there is no point continuing the script.
A response that took 900 ms instead of 300 ms is still a response — you want the
run to finish and the slowness recorded. That is `.check()`.

See [Writing Probes](writing-probes.md).

## A run, its calls, and its assertions

One execution of a service's script is a **probe run**. A run contains one or
more **calls** (HTTP requests), and each call carries:

- a full timing breakdown — DNS, connect, TLS, time-to-first-byte, transfer;
- the response metadata — status, headers, size;
- every **assertion** that was evaluated, with its scope, what it expected, and
  **what it actually saw**.

That last part is why failures are diagnosable after the fact. The result does
not say "assertion failed" — it says the status scope expected 200 and got 503,
at a call that took 41 ms to first byte. You do not have to reproduce it.

See [Reading Results](results.md).

## Agents run the probes

Tracedown never makes the HTTP call itself. **Agents** do — separate processes
you deploy wherever you need the check to originate from, which is how you
monitor from more than one place.

The scheduler dials the agent over mutual TLS, hands it the script and the
resolved variables, and gets back the raw result. The agent holds no state and
decides nothing; it executes and reports.

A service can restrict which agents may run it. If it names none, every active,
healthy agent is eligible. See [Services](services.md).

## Alerting lives in the script

There is no rule builder. A probe emits notifications from inside the script,
attached to the assertion they concern:

```lace
get("$p.baseUrl/api/orders")
.expect(
  status: {
    value: 200,
    options: {
      notification: template("server_error_alert")
    }
  }
)
```

The script already knows what it asserted and why that assertion matters, so
that is where the alert belongs. The platform's job is delivery — email,
webhooks, who is eligible, and who has silenced what.

See [Notifications](notifications.md).
