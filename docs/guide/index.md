---
description: "The Tracedown user manual: workspaces, projects and services, writing probe scripts in Lace, reading results, and getting told when one of your APIs breaks."
---
# User Manual

This section is for people using Tracedown: setting up checks, reading what
came back, and getting told when something breaks. If you are the one running
the installation, start with [Installation](../install/index.md) instead.

## The short version

You organise work into **workspaces** and **projects**, and the thing that
actually gets monitored is a **service**: one probe script, one schedule, and a
policy for which agents run it. The script is written in
[Lace](https://lacelang.dev), and it decides both what to check and what is
worth alerting on.

That last point surprises people, so it is worth saying up front: **there is no
alert-rule builder.** Alerting is expressed inside the probe script, next to the
assertion it relates to. See [Notifications](notifications.md) for why.

## Read in this order

<div class="grid cards" markdown>

-   **[Concepts](concepts.md)**

    ---

    The hierarchy, what a probe run actually is, and the vocabulary the rest of
    these pages assume.

-   **[Workspaces & Projects](workspaces-and-projects.md)**

    ---

    Where things live and why the nesting exists.

-   **[Services](services.md)**

    ---

    Creating a check: schedule, agents, queue policy, run-now.

-   **[Writing Probes](writing-probes.md)**

    ---

    Lace in the editor: assertions, chaining, and emitting alerts.

</div>

## Then, as you need them

| Page | Read it when |
|---|---|
| [Variables](variables.md) | You need credentials or a base URL in a script, or a value carried between runs. |
| [Reading Results](results.md) | A probe failed and you want to know why, or you want the numbers in Grafana. |
| [Notifications](notifications.md) | You want alerts to reach a person or a webhook. |
| [Silences & Quiet Hours](silences.md) | The alerts are reaching you too often, or at 3am. |
| [Maintenance Windows](maintenance-windows.md) | You have planned downtime and don't want it recorded as an outage. |
| [Users & Permissions](users-and-permissions.md) | Someone else needs in, or needs to stop getting paged. |
| [Your Account](account.md) | Two-factor, sessions, password, personal settings. |
