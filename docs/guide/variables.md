---
description: "Scoped variables in Tracedown probes: the $o., $w., $p. and $s. prefixes, secrets encrypted at rest, writeback, computed values and configuration variables."
---
# Variables

Variables keep credentials, base URLs and counters out of probe scripts. They
resolve down the hierarchy, so you define a value once at the level where it is
true and every service beneath inherits it.

## Scopes

Each level has its own prefix, and a script names the scope it reads from
explicitly:

| Prefix | Level | Edited in |
|---|---|---|
| `$o.` | Organization | Infrastructure → Org variables |
| `$w.` | Workspace | The workspace's Variables tab |
| `$p.` | Project | The project's Variables tab |
| `$s.` | Service | The service panel's Variables tab |

A service's script can reference any of its ancestors' scopes — `$o.apiToken`
reads the organization's variable, `$p.baseUrl` the project's — which is what
lets you define a value once at the level where it is true and use it from
every service beneath. The prefix is part of the reference, not a search hint:
`$p.baseUrl` reads the project scope and nothing else, and a `$s.baseUrl`
defined alongside it is a different variable, not an override. There is no
implicit fallback chain — a reference either names a scope that holds the
variable, or it resolves to nothing.

The Variables tab of any resource shows its own scope alongside the ancestor
scopes a script here could reference, but only the resource's own scope is
editable — the others are shown read-only, with the level they come from. That
is intentional: it lets you see what a script can reach without walking the
tree yourself, while keeping the edit in the one place that owns it.

!!! note "Prefixes address scope, storage is per level"
    The `$o.` / `$w.` / `$p.` / `$s.` prefix says which level a reference reads.
    The stored variable itself is keyed by its bare name within that level —
    the prefix is not part of the stored name.

## Types

| Type | Encrypted at rest | Visible after saving | Writable by a script |
|---|---|---|---|
| **Secret** | Yes | Never | No |
| **Variable** | Yes | On demand, via reveal | No |
| **Metric** | No | Always | **Yes** |

**Secrets** are write-only from the UI's point of view: once saved, nothing can
display the value again. Use them for passwords and API tokens, where the
inability to read it back is the feature.

**Variables** are also encrypted, but can be revealed on demand. Use them for
things that are sensitive but that you legitimately need to check — a base URL
with an embedded key, an account identifier.

**Metrics** are plaintext, always visible, and — uniquely — **a probe script can
write to them**. That is what makes them metrics rather than settings.

## Writeback

A script can store a value for the next run:

```lace
get("$p.baseUrl/api/stats")
.expect(status: 200)
.store({ "$lastCount": this.body.count })
```

Note the two forms in that script. The write-back target uses the **bare**
`$name` form — write-backs always land at the **service** scope, so the target
carries no prefix. Reading the value back on the next run uses the scoped
form, `$s.lastCount`. Writing to a scoped name like `"$s.lastCount"` does not
do what it looks like — it creates a separate variable rather than updating
`lastCount`.

A write-back creates the variable as a metric if it does not exist, and only
ever overwrites **metric** variables: a write-back whose name collides with a
secret or encrypted variable is skipped with a warning rather than applied.

Values written this way are persisted after the run and injected into the next
one. This is what makes change detection possible: compare what you see now
against what you stored last time, and alert on the delta rather than on an
absolute threshold.

Note the difference from `$$` run-scope variables, which live only for the
duration of a single run and are used to pass values between calls in a chain —
see [Writing Probes](writing-probes.md).

!!! note
    Writeback is applied per run, not per call. A value stored anywhere in the
    script lands once the run completes.

## Computed variables

Some variables are maintained by the platform and are read-only. They are
injected at run time, so a script can use them without you defining anything:

| Variable | Value |
|---|---|
| `$s.name` | The service's name |
| `$s.lastStatus` | The status of the previous run |
| `$s.lastStatusSince` | When the service entered that status |
| `$s.lastStatusConsecutive` | How many runs in a row have reported it |
| `$p.name` | The project's name |
| `$w.name` | The workspace's name |

`$s.lastStatusConsecutive` is the useful one for alert suppression: it lets a
script stay quiet until a failure has repeated, instead of paging on the first
blip.

## Configuration variables

A service is seeded with configuration variables — boolean toggles that change
how the platform treats its runs. They can be edited but not deleted. Today the
seeded one is `trackBaseline` (default off), which enables rolling-baseline
tracking for the service.

## Using them in scripts

Reference a variable with its scope prefix and name. Secrets are decrypted at
dispatch and handed to the agent with the script — they are never written into
the script itself, and never stored in the result:

```lace
post("$p.baseUrl/login", {
  body: json({ email: "$o.apiUser", password: "$o.apiPassword" })
})
.expect(status: 200)
```

!!! tip "Put values at the level that owns them"
    A base URL that every service in a project shares belongs on the project,
    not copied into each service. If you change environments later, you change
    it once. The same reasoning applies to credentials at the workspace or
    organization level.
