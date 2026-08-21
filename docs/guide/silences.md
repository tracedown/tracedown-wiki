---
description: "Silences and quiet hours mute your own Tracedown notifications per user and per resource, while probes keep running and the recorded history stays honest."
---
# Silences & Quiet Hours

Silences and quiet hours are how you stop notifications reaching **you** without
changing what anyone else receives and without touching what Tracedown records.
Probes keep running, results keep landing in history, success rates stay honest.
Only your mail stops.

This separation is the point. Muting an alert should never cost you the data
behind it.

## Silences

A silence is **per user and per resource**. You create one with the bell icon,
which appears on a workspace, a project, a service, a project card and a service
row.

Silences are personal. Silencing a service mutes your notifications for it and
nobody else's — there is no shared "mute" that quietly stops your colleagues
being paged.

### Silencing a parent

Silencing an ancestor covers everything beneath it. Silence a workspace and you
stop notifications from every project and service inside it. The descendants
then show their bell as locked, with the explanation:

> Silenced via a parent resource — manage it there. An explicit grant on this
> resource would keep it independent.

There is one exception, and the second sentence of that message points at it.

### Most-specific-grant-wins

!!! info "The rule"
    A silence applies at or below your **most specific grant**. If you hold an
    explicit grant on a particular resource, a broader silence higher up does
    not mute it — your own setting for that resource wins.

So if you silence a workspace but hold an explicit grant on one service inside
it, that service keeps notifying you. Its bell stays live rather than locked,
because your grant on it is more specific than the workspace silence.

This is not a UI quirk. It is exactly the rule the notification dispatcher
applies when it decides who receives an alert, and the interface is simply
showing you the outcome in advance. Understanding that explains the behaviour:
an explicit grant on a specific service is a deliberate statement that you care
about that service in particular, and a broad sweep of the workspace it happens
to live in should not silently override it. A grant you went out of your way to
hold outranks a mute you applied to everything.

Since eligibility follows grants, the bell only renders for users who hold a
grant on the resource. Someone with no grant receives no notifications for it
and so has nothing to silence. See
[Users & Permissions](users-and-permissions.md).

### Managing silences centrally

Bells are convenient in the moment and easy to forget about. Every mute you
create with one is listed in one place: **Account -> Silences**, under *Muted
resources*.

Each entry carries a scope badge — **Service**, **Project**, **Workspace** or
**Global** — and can be removed from there. This is the page to check when a
service you expected to hear from has gone quiet: a silence you set during a
deployment three weeks ago is invisible from everywhere except here and the
resource's own bell.

## Quiet hours

Quiet hours are **account-wide** rather than per resource: a recurring window —
daily, or on the weekdays you choose — during which no notifications are sent
to you at all, in a timezone you choose.

Where a silence answers "which resources", quiet hours answer "when". They are
the right tool for not being emailed while asleep, and the wrong tool for a
noisy service — for that, silence the service.

Overnight windows are supported. A 22:00–07:00 window spans midnight and
behaves as one continuous nine-hour period, not two fragments you have to
configure separately.

Quiet hours reuse the same recurrence builder as [maintenance
windows](maintenance-windows.md), so the controls are the ones you already know
from scheduling downtime. One difference is worth knowing if you set quiet
hours through the API rather than the editor: a quiet-hours rule that omits its
timezone evaluates in **UTC**, not in the organization's default timezone the
way a maintenance window does. The editor always writes a timezone, so this
only concerns rules created programmatically.

!!! note "Quiet hours are not a silence entry"
    Quiet hours do not appear in the **Muted resources** list on the Silences
    page. That list shows bell-created mutes only. If you have quiet hours set
    and go looking for them among your silences, you will not find them — they
    are configured in their own section of your account, and their absence from
    the mute list is intended rather than a bug.

## Choosing between the three

| | Maintenance window | Silence | Quiet hours |
|---|---|---|---|
| Scope | Per service | Per user, per resource | Per user, account-wide |
| Probing | Paused | Continues | Continues |
| Results recorded | No | Yes | Yes |
| Affects | Everyone | Only you | Only you |
| Driven by | A schedule you set | The resource | The time of day |

Read the table top to bottom and the decision usually makes itself:

- Deploying, and the service will legitimately fail? Use a [maintenance
  window](maintenance-windows.md). Probing stops, nothing is recorded, nobody is
  alerted. The cost is that the outage leaves no trace in your history — which
  is the intent for planned work, but means you cannot review it later.
- Something is known-broken, being worked on, and you want the data but not the
  mail? Use a **silence**. History stays complete and your colleagues carry on
  receiving alerts.
- You simply do not want email overnight? Use **quiet hours**.

The common mistake is reaching for a maintenance window to stop noise from a
service that is genuinely failing. That does stop the noise, but it also stops
the probing — so the record of the incident you are trying to fix has a hole
in it exactly where you needed the evidence.

## What silences do not cover

Silences and quiet hours apply to **email**. Webhook deliveries are bound to
resources rather than resolved to individual people, so they are not affected by
anyone's personal settings and will keep firing through your quiet hours.

If a webhook feeds a paging or chat integration you need to quieten, pause its
binding instead — each webhook binding has its own enable/pause toggle. Note
that this affects everyone, not just you. See
[Notifications](notifications.md).
