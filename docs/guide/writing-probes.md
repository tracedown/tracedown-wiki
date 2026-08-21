---
description: "Write API monitoring probes in the Lace language: the validating script editor, templates, assertions, chaining calls, emitting alerts and using variables."
---
# Writing Probes

A probe is a [Lace](https://lacelang.dev) script attached to a service. This page
covers writing one in Tracedown — the editor, the parts of the language you will
reach for first, and how alerts get emitted.

Lace has its own documentation at [lacelang.dev](https://lacelang.dev), and it is
the authority on the language. This page is the working subset plus the parts
that are specific to Tracedown.

## The editor

The script editor validates as you type. It parses and validates roughly half a
second after you stop typing, underlines problems in place, and reports a count.

!!! warning "A script with validation errors cannot be saved"
    Save is blocked while the script is empty or has validation errors. This is
    deliberate — a service whose script does not parse cannot be probed, so
    there is nothing useful to store.

The floating toolbar has three actions: **Load template**, **Save to file**
(downloads a `.lace` file), and **Load from file**.

!!! danger "Ctrl+S downloads, it does not save"
    <kbd>Ctrl</kbd>/<kbd>Cmd</kbd>+<kbd>S</kbd> in the editor downloads the
    script as a `.lace` file named after the service. It does **not** save to the
    server. Use the form's save button for that.

### Templates

Scripts can be saved as reusable templates, scoped to the organization or to a
workspace. **Load template** opens the library with a read-only preview; using
one **replaces** the current script rather than merging into it. Templates are
the right home for the check your team writes over and over — an auth flow, a
health endpoint convention.

## The shape of a script

A script is a sequence of calls. Each call is a method, a URL, and an optional
config object, followed by assertions:

```lace
get("https://api.example.com/health", {
  headers: { Accept: "application/json" }
})
.expect(status: 200)
.check(totalDelayMs: { value: 800 })
```

Config — headers, body, timeout, redirects — goes in the **second argument**,
not in chained methods.

!!! note "Timeouts are per call, not per service"
    People look for a timeout field on the service form and do not find one.
    Timeouts and redirect limits are set per call in the script's config object,
    because in a multi-step flow "the timeout" is rarely one number.

## Assertions

`.expect()` fails the run and stops. `.check()` records the failure and carries
on. Reach for `.expect()` when the thing is *wrong* and for `.check()` when it
is *degrading* — see [Concepts](concepts.md).

Both take one or more **scopes**:

| Scope | Default op | Asserts on |
|---|---|---|
| `status` | `eq` | HTTP status. An array passes if any element matches. |
| `body` | `eq` | Response body — a literal, a variable, or `schema()`. |
| `headers` | `eq` | Each key/value; header names are case-insensitive. |
| `bodySize` | `lt` | Body size threshold (`"50k"`, `"10mb"`). Also gates body capture. |
| `size` | `eq` | Exact body size in bytes. |
| `totalDelayMs` | `lt` | Total response time. |
| `dns` | `lt` | DNS resolution time. |
| `connect` | `lt` | TCP connect time. |
| `tls` | `lt` | TLS handshake time. Skipped on plain HTTP. |
| `ttfb` | `lt` | Time to first byte. |
| `transfer` | `lt` | Body transfer time. |
| `redirects` | `eq` | Redirect hop URLs. Supports a `match` of `first`/`last`/`any`. |

Threshold scopes take `{ value: N }`:

```lace
get("https://www.example.com/")
.expect(
  status: 200,
  totalDelayMs: { value: 3000 }
)
.check(
  dns:      { value: 80 },
  connect:  { value: 150 },
  tls:      { value: 200 },
  ttfb:     { value: 500 },
  transfer: { value: 400 }
)
```

Asserting on each timing phase separately is the point of the exercise: "slow"
is not a diagnosis, but "TLS handshake went from 40 ms to 900 ms" is.

## Chaining calls

Capture a value with `.store()` and use it in a later call. Run-scope variables
use the `$$` sigil:

```lace
post("$p.baseUrl/login", {
  body: json({ email: "$o.apiUser", password: "$o.apiPassword" })
})
.expect(status: 200)
.store({ "$$token": this.body.access_token })

get("$p.baseUrl/orders", {
  headers: { Authorization: "Bearer $$token" }
})
.expect(status: 200)
```

`this` refers to the current call's response. A `$$var` may be assigned **once**
per script — a second assignment is a validation error, caught before the script
ever runs.

## Emitting alerts

Notifications are attached to the assertion they concern, via its `options`:

```lace
get("$p.baseUrl/api/orders")
.expect(
  status: {
    value: 200,
    options: {
      notification: text("Orders API returned an unexpected status")
    }
  }
)
```

Three forms are available: `text("...")` for a literal message, `template("name")`
to reference a [notification template](notifications.md) defined in the app, and
`structured({...})` for machine-readable failure detail. `op_map({...})` picks
between them based on *how* the assertion failed:

```lace
get("$p.baseUrl/api/orders")
.expect(
  status: {
    value: 200,
    options: {
      notification: op_map({
        "404": template("not_found_alert"),
        "500": template("server_error_alert"),
        "default": template("unexpected_status_alert")
      })
    }
  }
)
```

If an assertion fails and you set no `notification`, a structured notification
with the failure details is emitted anyway — you do not have to annotate every
assertion to get alerted.

Templates must be **bound to the project** to be referenceable by name. See
[Notifications](notifications.md).

## Using variables

Variables are injected by Tracedown before the run, addressed by scope: `$o.`
for organization, `$w.` workspace, `$p.` project, `$s.` service — the prefix
names the level the value is read from. Secrets are decrypted at dispatch and
never stored in the script.

A script can also write values **back** for the next run, which is what makes
change detection and rolling counters possible. See [Variables](variables.md).

## Testing a script

Save the service, then use **Run now** on the service panel to queue a run
immediately rather than waiting for the schedule. The service must be active and
have a script. Then read the result — every assertion records what it actually
saw, so a failed run usually explains itself. See [Reading Results](results.md).
