---
description: "A Tracedown service is one probe script, one cron schedule and a dispatch policy. Creating one, setting probe mode, queue policy, agents, webhooks and deletion."
---
# Services

A service is the thing you are monitoring. Concretely it is three things bound
together: a Lace probe script that says *what* to check, a schedule that says
*when* to check it, and a dispatch policy that says *how* the check is handed to
your probe agents. Services live inside a project, which in turn lives inside a
workspace — see [Workspaces & Projects](workspaces-and-projects.md) for how that
hierarchy shapes permissions and variables.

Almost everything else in Tracedown hangs off a service: results, notifications,
silences, variables and usage are all scoped to one. Getting the service right
is most of the work; the rest of the product mostly reports on it.

## Creating a service

Services are created inline from the project's service list — press **New
service**, give it a name, and it appears immediately. There is no wizard, and
you are not asked for anything else up front, because a service is only useful
once it has a script and you write that in the editor.

A new service starts:

- **inactive** — it will not be dispatched until you enable it;
- on the default schedule `*/5 * * * *` (every five minutes);
- with no script;
- opened straight into edit mode, with the script editor focused on the
  work that actually matters.

A service **cannot be enabled until it has a script**. There is nothing to run
otherwise, so the Enable action stays disabled until you have saved one.

!!! note "A service has no URL of its own"
    Selecting a service is local state inside the project view — the address bar
    does not change. That means a service **cannot be linked to directly**: you
    cannot bookmark one, and pasting your address bar into a chat sends your
    colleague to the project, not to the service you were looking at. Point
    people at the project and name the service.

## The service list

The list groups services into three collapsible sections, and the grouping is
the point: **New** first (nothing has run yet, so there is no verdict), then
**Failing**, then **Healthy**. On a project with a hundred services, the ones
that need attention sit above the healthy bulk, which can stay folded away.

Each row carries enough to triage without opening anything:

| Element | What it tells you |
|---|---|
| Status dot | The last recorded status |
| Name | — |
| Silence bell | Whether notifications are currently silenced, and lets you toggle it |
| Inactive badge | The service exists but is not being dispatched |
| Success rate | Share of successful runs over the service's recorded history |
| Schedule | The cron expression, so you know how stale "last run" can be |
| Up for / Last online | How long it has been healthy, or when it last was |
| Failure preview | The assertions that failed on the last run, abbreviated |

The failure preview is the reason you often do not need to open the service at
all: `status: expected 200, got 503` in the list answers the question on its
own. When it does not, open the service and read the run — see
[Reading Results](results.md).

## Configuring a service

Press **Edit** on the service panel to get the form. Every field below lives
there.

| Field | Control | Notes |
|---|---|---|
| Name | Text | — |
| Schedule | Text | A cron expression. Default `*/5 * * * *` |
| Probe mode | Select | `consecutive` (default), `simultaneous`, `random` |
| Queue policy | Select | `skip` (default), `enqueue_once` |
| Maintenance window | Builder | See [Maintenance Windows](maintenance-windows.md) |
| Probe script | Lace editor | See [Writing Probes](writing-probes.md) |
| Probe agents | Pill picker | Restricts which agents may run this service |
| Webhooks | Bindings list | See [Notifications](notifications.md) |

### Schedule

The schedule is a plain **cron expression**, typed as text. There is no builder
and no natural-language parser, so `*/5 * * * *` means what a cron user expects
it to mean and nothing is translated behind your back. Pick an interval you can
justify: every probe run costs a real request against the endpoint you are
monitoring, and a one-minute schedule on fifty services is fifty requests a
minute of traffic you are generating yourself.

### Probe mode

Probe mode decides how a run is spread across the agents eligible for the
service. It only matters once you have more than one agent.

| Mode | Behavior | Reach for it when |
|---|---|---|
| `consecutive` | Runs one agent at a time, rotating through the pool in order | You want coverage across locations over time at one run's cost — the sensible default |
| `simultaneous` | Runs on every available agent at once | The point of the check is comparing locations *at the same moment*, or you want a failure confirmed from everywhere before you trust it |
| `random` | Each run picks a random agent from the pool | You want sampling without the strict rotation, e.g. to avoid a probe pattern that lines up with something on the target |

`simultaneous` multiplies your outbound traffic by the number of agents on every
tick. That is exactly what you want for a "is it down for everyone or just
Frankfurt" check and exactly what you do not want as a default.

### Queue policy

Queue policy answers what happens when a scheduled run comes due while the
previous run of the same service is still in flight. This is not a rare corner:
a probe that walks a five-step login flow against a slow staging box can easily
outlive a one-minute schedule, and without a policy those runs pile up — each
tick starting another overlapping probe against an endpoint that is already
struggling, which is a fine way to turn a slow service into a dead one.

| Policy | Behavior |
|---|---|
| `skip` | If a probe is already running, the next scheduled run is skipped |
| `enqueue_once` | If a probe is already running, exactly one run is queued; further triggers are dropped until the queue clears |

`skip` is the default and the safer choice — it lets the service fall behind
rather than amplify load. Choose `enqueue_once` when you would rather not lose a
data point after a single slow run, and can accept that a run may start slightly
late.

### Probe script

The script is written in the built-in Lace editor, which validates as you type.
The editor also lets you load a saved **script template**, and save the current
script to a `.lace` file or load one from disk. Writing the script itself is a
subject of its own — see [Writing Probes](writing-probes.md). Values you do not
want hardcoded (hosts, tokens, credentials) come from
[Variables](variables.md).

!!! warning "There is no timeout field on a service — and there should not be"
    People look for one. Timeouts and redirect limits are **per call inside the
    script**, not per service, because a service is often several calls with
    genuinely different budgets: a login POST you will wait two seconds for,
    followed by a report endpoint you will wait ten for. A single service-level
    number could not express that. Set them in the call's config object:

    ```lace
    get("https://api.example.com/health", {
      timeout: { ms: 3000, action: "fail" },
      redirects: { follow: true, max: 3 }
    }).expect(status: 200).check(ttfb: { value: 500 })
    ```

### Probe agents

By default a service is eligible to run on **every active, healthy agent** — no
selection means no restriction, which is why the picker starts empty. Add agents
only to pin the service to exactly those: a probe of an internal service that is
only routable from one network, or a check whose whole purpose is measuring from
a particular region.

If a dispatch fails before the probe can start — the agent cannot be reached, or
it turns the job away — the run moves to the next eligible agent rather than
being lost, for up to three attempts inside a twenty-second window. Restricting
a service to one agent gives that up: when that agent will not take the job, the
run is recorded as `skipped` instead.

A dispatch that fails *after* the agent has taken the job is never retried, and
you would not want it to be. The agent may already have called your API, and
re-running would mean a second POST, a second delete, a second of whatever the
script does. Such a run is recorded as it stands: `error` when the agent
answered with a fault, `timeout` when it never answered at all. See
[Reading Results](results.md#what-a-status-means).

!!! note "Agent selection saves on its own"
    The agent picker writes immediately when you add or remove an agent — it is
    not part of the form's Save, and Cancel will not undo it.

### Response bodies

Whether a run keeps the response body of each call. On by default, so a failure
can be opened and read.

Turning it off is a real trade and worth making deliberately: runs still record
status, timings and every assertion, but **when this service fails there will be
no stored body to inspect** — which is usually the thing you want most at that
moment. Reach for it when the bodies are large, or when they carry something you
would rather not keep at all.

The setting is a ceiling, not a switch. Two other things can still withhold a
body when this is on: the probe script has to ask for the body in the first
place, and a service targeting an
[unverified domain](../admin/troubleshooting.md) has saving disabled by the
anti-abuse policy regardless. Nothing overrides this setting in the other
direction — off means off.

The config view shows the current state as **Saved** or **Not saved**, so you do
not have to open the edit form to check.

### Webhooks

Webhooks are bound to the service from the edit form, each binding with its own
enabled toggle so you can mute one target without unbinding it. What gets sent
and when is covered in [Notifications](notifications.md).

### Deleting

**Delete service** is a danger button: hold it for three seconds. Deletion
removes the service and hides its results and history immediately; the
underlying data is cleaned up later by the retention and purge jobs. It is not
part of the form's Save — it happens the moment the hold completes.

## Saving

The form saves **configuration and script separately**, and only sends what you
actually changed. The consequence worth knowing is that the script save carries
a **version** and uses optimistic locking: if the script changed since you
opened the editor — a colleague in another tab, or you in another window — your
save is **rejected** rather than quietly overwriting their work — you get an
error saying the script changed while you were editing. Reopen the service to
pick up the current script and reapply your change.

Save is blocked outright while:

- the script is empty;
- the script has validation errors (the form says *Script has validation
  errors*);
- the maintenance window is incomplete — a weekly window with no weekday
  selected.

## Running, pausing, and silencing

The service panel header carries the actions you reach for between edits.

| Action | Availability | Effect |
|---|---|---|
| Run now | Only when the service is active **and** has a script | Queues an immediate one-off run; the UI confirms *Probe run queued* |
| Enable | Requires a script | Starts scheduled dispatch |
| Pause | Always allowed | Stops scheduled dispatch. Pausing an active service is a three-second hold, like the delete button |
| Edit | With edit rights | Opens the form |
| Close | Always | Closes the panel |
| Silence bell | — | Stops notifications while probing continues |

Pausing is always permitted — you can always stop a noisy service, even if it is
in a state where you could not have enabled it. **Run now** queues the run; the
scheduler dispatches it asynchronously, so the result appears when it appears
rather than the moment the toast does.

Note the three ways of making a service stop bothering you, because they are not
interchangeable. **Pause** stops probing entirely and indefinitely. A
**silence** keeps probing and only stops the notifications, so your history
stays intact — see [Silences & Quiet Hours](silences.md). A **maintenance
window** pauses probing on a recurring schedule, for planned work — see
[Maintenance Windows](maintenance-windows.md).

## The config view

When you are not editing, the Config tab is a read-only summary: probe mode and
queue policy (each with a help tooltip spelling out what the modes do), the
maintenance window rendered as a readable label, a metrics summary, and the
script. A service that has a script but has never been dispatched says *Probe
has not run yet* — that is the expected state for a freshly enabled service, not
a fault.

## Tabs

| Tab | Shows | Requires |
|---|---|---|
| Config | Configuration and script | — |
| Variables | Variables scoped to this service | — |
| Probe history | Past runs and their steps | Appears once the service has metrics |
| Statistics | Aggregated metrics for this service | Appears once the service has metrics |
| Users | Who has access to this service | Edit rights |
| Usage | Resource usage for this service | Edit rights |

Probe history is absent, not empty, before the first run — if the tab is not
there, the service has not produced a result yet. See
[Reading Results](results.md) for what the tab contains, and
[Users & Permissions](users-and-permissions.md) for how access is granted.
