---
description: "Why Tracedown nests workspaces inside organizations and projects inside workspaces: they are the levels at which variables and access grants cascade downward."
---
# Workspaces & Projects

Tracedown organizes everything into a four-level tree:

```
organization → workspace → project → service
```

This page covers the two middle levels. The organization is the account boundary
and the service is where a probe actually lives — [Concepts](concepts.md)
describes the whole model, and [Services](services.md) covers services in
detail.

## Why the middle levels exist

Workspaces and projects are containers, and it is fair to ask why you need two
of them. The answer is that they are the levels at which **variables and access
cascade**, and that makes them structural rather than cosmetic:

- **Variables are shared downward.** Define a base URL, a token or a
  credential once at the workspace or project level and every service beneath
  it can reference it by scope (`$w.`, `$p.`). The alternative — the same
  staging hostname pasted into forty services — is the thing you are trying to
  avoid. See [Variables](variables.md).
- **Access cascades the same way.** A grant on a workspace or project extends to
  everything inside it, including resources created later. Grant access once at
  the level a team actually owns rather than service by service. See
  [Users & Permissions](users-and-permissions.md).

So the useful question when structuring the tree is not "how do I want to group
these visually?" but **"what do these services share, and who owns them?"** A
good split is one where the shared configuration sits at the container level and
the grants line up with real teams. If you find yourself granting every project
in a workspace to the same people one at a time, that grant belongs on the
workspace.

## Workspaces

A workspace is a container of projects and the top of the part of the tree you
navigate. Within one you can manage workspace variables, grant access, bind
webhooks, see rolled-up metrics and usage, and silence notifications.

### Creating and switching

The **workspace selector** in the header bar shows the current workspace and
lists the others; picking one switches to it. The selector also offers inline
creation at the top of the dropdown, so you rarely need to go anywhere to
make a workspace.

If the organization has no workspaces — or you have access to none — the
dashboard shows an empty state with an inline create form instead. Navigating to
the app root always redirects to your selected workspace, or the first one you
can see if you have not selected one, so `/` is a shortcut to where you were.

!!! note "Creating a workspace needs org-wide workspace write"
    The create option appears in the selector and the empty state only for users
    with **Write** on the `workspaces` section. Members whose access comes from
    resource grants can work inside the workspaces they hold but cannot create
    new ones — which is usually what you want, since a new workspace is a new
    top-level container nobody has been granted yet.

### Tabs

A workspace page carries a header with rolled-up statistics — its project and
service counts, plus the metrics window — and a silence bell.

| Tab | Visible to | Purpose |
|---|---|---|
| **Overview** | Everyone with access | The project grid |
| **Variables** | Everyone with access | Workspace-level variables (editable with write access) |
| **Users** | Write access | Resource grants on this workspace |
| **Settings** | Write access | Rename, webhook bindings, delete |
| **Usage** | Write access | Requests and network ingress/egress |

"Write access" here means the same rule as everywhere: organization `workspaces`
Write, ownership, or a Write-level grant on the workspace.

## Projects

A project is a container of services, inside a workspace. It has the same shape
as a workspace — Overview, Variables, and Users/Settings/Usage for people with
write access — and its header breadcrumbs back to its parent workspace.

Projects are created inline from the workspace **Overview**, which lists them as
a paginated card grid. Each card shows:

- the **service count**;
- **total probes** over the metrics window;
- the **success rate**, coloured by health;
- an **active/inactive dot**;
- a silence bell, if you hold a grant covering it.

The grid is the fastest read on a workspace's health — a project whose success
rate has dropped stands out without opening anything.

### What only exists at project level

Two things make projects more than "workspaces, but smaller":

**The Grafana integration.** The project **Settings** tab carries a Grafana
integration card that exposes that project's probe metrics on a Prometheus
scrape endpoint. You enable the integration, receive a bearer token — copy it
immediately, it is not shown again — point a Prometheus data source at the
scrape endpoint with the token as an `Authorization: Bearer` header, and
optionally narrow the **service scope** rather than exporting every service. The
token can be regenerated, which invalidates the old one.

**Notification template bindings.** Notification templates are bound to
projects, and a template is only available to the projects it is bound to — a
script referencing an unbound template silently falls back to the default
message. The project is therefore
the unit that decides which templates its services can use. The bindings
themselves are managed from the notification templates surface rather than from
inside the project; see [Notifications](notifications.md).

## Renaming, webhooks and deletion

Both levels share the same Settings tab, so the mechanics are identical:

- **Rename** — a name field and a save action. Renaming is safe; nothing
  references resources by name.
- **Webhook bindings** — bind webhook endpoints to this workspace or project so
  events from anything inside it are delivered. See
  [Notifications](notifications.md).
- **Danger zone** — a delete button you must **hold for 3 seconds**. It is a
  hold rather than a confirmation dialog because a dialog trains you to click
  through it. After a successful delete you are returned to the dashboard.

!!! danger "Deleting a container deletes its contents"
    Deleting a workspace takes its projects, their services, and the probe
    history underneath them. Deleting a project takes its services and their
    history. There is no per-item confirmation listing what is about to go, and
    the three-second hold is the only thing standing between you and the whole
    subtree.

    If what you actually want is for a service to stop probing, disable the
    service instead — see [Services](services.md).

## A worked structure

There is no single right layout, but the cascade suggests a shape. If your
organization runs several products, each with its own team and its own
environments, a structure that pays for itself looks roughly like:

- **Workspace per product or team** — the level you grant to the team, and where
  you define what every service in the product shares (the API hostname, an
  organization-wide credential override).
- **Project per environment or bounded area** — production, staging, the public
  API, the internal API. This is where environment-specific variables belong,
  where the Grafana export is scoped, and what shows up as a card on the
  workspace overview.
- **Service per endpoint or flow** — the thing that actually runs a probe on a
  schedule.

The test of a good structure is whether a new service inherits nearly everything
it needs the moment you create it in the right project, and whether the person
who owns it can already see it without anyone touching permissions. If both are
true, the tree is doing its job.
