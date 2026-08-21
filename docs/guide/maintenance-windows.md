---
description: "Maintenance windows pause probing of a Tracedown service on a recurring schedule - no requests, no results, no alerts. How they differ from a silence."
---
# Maintenance Windows

A maintenance window **pauses probing** for a service on a recurring schedule.
While the window is open the service is not dispatched at all: no requests are
made, no results are recorded, and consequently no notifications are sent.

That last clause is the whole design, and it is worth being precise about it,
because Tracedown gives you two ways to stop being paged and they are not
interchangeable:

| Tool | Probes | Results | Notifications | Use it for |
|---|---|---|---|---|
| **Maintenance window** | Paused | None recorded | None | Planned, recurring downtime |
| **Silence** | Keep running | Recorded as normal | Suppressed | Known noise you still want measured |

Reach for a maintenance window when the service is *expected to be down or
lying* — a nightly database restore, a deploy slot, a batch job that takes the
API offline. There is no truth to record during those minutes, so recording a
red bar every five minutes only pollutes your success rate and your history with
an outage you scheduled yourself.

Reach for a [silence](silences.md) when you want the data but not the pager: a
flaky third-party dependency you are already chasing, or an incident you are
actively working. The probes keep running, the history stays honest, and your
phone stays quiet.

!!! warning "A window is a blind spot you chose"
    A service inside its window is not being watched. If the maintenance
    overruns and the service is still broken when the window closes, the first
    you hear of it is the first probe after the window — so keep windows as
    tight as the work actually needs.

## Setting a window

The window editor sits in the service edit form, between the schedule controls
and the script — see [Services](services.md) for the rest of that form. It
offers three modes:

| Mode | Meaning |
|---|---|
| **None** | No window. The service is probed on its schedule, always. This is the default |
| **Daily** | The same range every day |
| **Weekly** | The same range, but only on the weekdays you select |

Both recurring modes take the same controls:

- **Start** and **end**, as hour and minute. Minutes move in five-minute steps —
  a window is planned maintenance, not a stopwatch.
- A **timezone**, chosen from a searchable IANA list. It is prefilled with your
  organization's default timezone (see below), so in the common case you can
  leave it alone.
- For **Weekly**, a row of **weekday pills**. At least one day must be selected;
  until it is, the editor says *Select at least one day* and Save stays blocked.

### Windows that cross midnight

If the end time is at or before the start, the window **crosses midnight**. A
window of `23:00–01:00` is two hours spanning the date boundary, not a
negative-length mistake — which is convenient, because most maintenance happens
exactly there.

If you set the start and end to the *same* time, the intent is ambiguous: it
could mean zero minutes or a full 24 hours. Rather than guess, the editor
**bumps the end forward by one hour** as soon as the two coincide. If you see
your end time move on its own, that is why.

### The timezone matters more than it looks

Your maintenance happens on a wall clock, and wall clocks move. A window pinned
to `Europe/Berlin` stays aligned with a 02:00 local backup across the daylight
saving change; the same window expressed in UTC drifts an hour twice a year and
misses the maintenance it was written for. Set the zone to the one the
maintenance is actually scheduled in.

The organization's default timezone is set in **Settings -> General**, and is
what prefills the picker. It is described there as the zone used "wherever a
timezone is optional" — a window that never sets its own zone evaluates in it.

The read-only Config view renders the window as a humanised label — *Daily
02:00–04:15 Europe/Berlin*, *Every Saturday, Sunday 23:00–01:00
America/New_York* — showing the window's own timezone, or the organization's
default when the window does not set one.

Clearing the window is a matter of selecting **None** and saving; that removes
the window entirely and the service returns to being probed on its schedule at
all times.

## How a window is stored

You do not need this to use the editor, but it explains the third mode you may
see and it is what you will find if you go looking through the API.

A window is encoded as `RRULE/durationMinutes[/tz]` — an iCalendar recurrence
rule giving the *start* occurrences, a duration in minutes giving the length,
and an optional trailing IANA timezone. A daily window from 02:30 to 04:45 is:

```text
FREQ=DAILY;BYHOUR=2;BYMINUTE=30/135
```

A weekly window across midnight, in Berlin time:

```text
FREQ=WEEKLY;BYDAY=SA,SU;BYHOUR=23;BYMINUTE=0/120/Europe/Berlin
```

An empty value means no window. Omitting the timezone means the rule reads the
organization's default timezone.

### Custom (set via API)

The editor deliberately models a *small* subset of what an RRULE can express:
one recurring range, daily or on chosen weekdays. That covers essentially all
real maintenance schedules and keeps the control readable.

If a service's window was set through the API to something outside that subset,
the editor shows the mode **Custom (set via API)** and the Config view prints
the raw rule in monospace instead of a friendly label. The rule is **passed
through untouched** — editing the service's name or schedule will not mangle it.
Switching the mode away from Custom replaces it, and there is no undo, so do not
touch it unless you mean to.
