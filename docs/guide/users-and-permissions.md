---
description: "Access in Tracedown runs on two axes: org-wide permission sections and per-resource grants on workspaces, projects and services. Plus groups, invites and TOTP."
---
# Users & Permissions

Access in Tracedown is decided along **two independent axes**, and almost every
confusion about "why can this person not see that workspace?" comes from
conflating them:

1. **Organization permission sections** — broad, org-wide capabilities. May you
   manage members? Edit webhooks? Touch organization settings?
2. **Resource grants** — access to one specific workspace, project, or service,
   handed out individually.

They are evaluated separately and neither is a superset of the other. A user can
hold write on the `webhooks` section and still see no workspaces at all. A user
can be granted a single project and never see the members area. The design is
deliberate: it lets you give an on-call engineer everything they need for one
team's services without making them an organization administrator.

| | Organization sections | Resource grants |
|---|---|---|
| Scope | The whole organization | One workspace, project or service (and everything inside it) |
| Granted to | Users and groups | Users and groups |
| Managed in | **Users → Members**, expanding a member's row | The **Users** tab of the workspace, project or service |
| Levels | None / Read / Write | None / Read / Write |
| Answers | "What kind of administrator is this person?" | "Which parts of the tree does this person work on?" |

!!! tip "Which one do you want?"
    If you are about to set the `workspaces` section to Read just so somebody
    can look at one project, stop — that grants them **every** workspace in the
    organization. Leave `workspaces` at None and give them a grant on that
    project instead. The in-app help says exactly this, and it is the single
    most useful habit on this page.

## Organization permission sections

Every membership carries a level for each of seven sections. The levels are
ordered — Write implies Read, Read implies None — and are stored numerically as
**None (0)**, **Read (1)**, **Write (2)**.

| Section | What it covers |
|---|---|
| **Users** | The members area. Read views members, groups and their permissions; Write invites users, manages groups and edits permissions. |
| **Settings** | Infrastructure-level configuration: probe agents, organization variables, API keys, the audit log and the warning log. Read views them; Write manages them. |
| **Domains** | Read views verified domains; Write adds and removes them. |
| **Webhooks** | Read views webhook endpoints; Write creates and edits them. |
| **Notifications** | The notification templates surface under Infrastructure. Read views it; Write manages templates and their project bindings. |
| **Org admin** | The high-trust General tab of organization settings. Write additionally reveals organization-wide usage. |
| **Workspaces** | Org-wide access to the resource tree. None means no workspace access by default — the setting to leave alone when you intend to scope access with grants. Read views every workspace in the organization; Write creates, edits and deletes **all** workspaces, projects and services. |

Each row of the matrix carries the same explanation as a help tooltip in the
app, so you do not have to remember this table while assigning permissions.

!!! warning "`workspaces` Write is the big one"
    It is org-wide write on the entire tree — every workspace, every project,
    every service, including ones created after you granted it. It is also what
    lets a user create a workspace in the first place. Treat it as an
    administrator-level permission, not as "can use the product".

The **organization owner** is effectively Write everywhere. Owner status is not
a row in the matrix and cannot be removed by editing permissions; it moves only
through an ownership transfer.

## Groups

A group is a named permission matrix that several members share. Groups are
worth using the moment you have more than a handful of people, because the
alternative — editing seven levels per person — drifts out of sync quietly.

From **Users → Groups** you can create a group, rename it, and delete it, and
each group carries its own full section matrix. Expanding a group shows its
member count and its members. Membership itself is managed from the other
direction too: expanding a member's row in **Users → Members** shows their
permission matrix on the left and their group membership on the right.

### Groups act as a floor, not an override

This is the mechanic to internalise. When a member belongs to a group, the level
that group grants appears in that member's matrix as a **floor**. The rule is
*most permissive wins*: the effective level is the higher of the member's own
level and the highest level any of their groups grants.

The UI makes this visible rather than mysterious. Levels below the floor are
disabled in the dropdown and annotated with *"Already granted by the *X*
group"*, naming the group responsible. Where a group grants Write, the whole
row is locked — there is nothing above Write to raise it to.

The practical consequences:

- An individual assignment can **raise** a level above the group floor.
- An individual assignment can never **lower** a level below the group floor.
- To reduce someone's access below what a group gives them, remove them from
  the group. Editing their personal matrix will not do it.

??? note "Why the individual level still matters under a floor"
    A member's own level is stored independently of the floor — the floor only
    affects what is displayed and selectable. Remove the member from the group
    and their own stored level takes effect again. This is why a group is a
    safe thing to hand out and take back: it does not overwrite anything.

### Default groups

Every new organization starts with four groups. They are ordinary groups — you
can rename, edit or delete them — and they exist to cover the common shapes.

| Group | Users | Settings | Domains | Webhooks | Notifications | Org admin | Workspaces |
|---|---|---|---|---|---|---|---|
| **Admins** | Write | Write | Write | Write | Write | Write | Write |
| **Users** | Read | Read | None | None | Read | None | Read |
| **Viewers** | None | None | None | None | None | None | None |
| **DevOps** | None | None | Write | Write | None | None | Read |

**Viewers** is deliberately empty on every section. That is not an oversight —
it is the group you put people in when their access should come *entirely* from
resource grants. **DevOps** owns the plumbing (domains and webhooks) and can see
the tree but not restructure it.

## Members

**Users → Members** lists everyone in the organization. Each row shows the
display name and email, an **Owner** badge where applicable, the groups they
belong to, and a **Disabled** badge when they are not active. Expanding a row
reveals the permission matrix and group membership.

From a member's row you can:

- **Disable** or **enable** them. Disabling keeps the account and all its
  permissions intact but blocks access — the right move for someone on leave, or
  as an immediate response while you work out what happened.
- **Delete** them, via a hold-to-confirm button. This is the permanent one.

## Invites

New members arrive by invitation from **Users → Members → Invite user**. You
supply an email address and, optionally, pre-assign groups.

The useful part is that an invitee is a first-class row before they exist as a
user. Expanding a pending invite shows the same permission matrix and group
picker as a real member, so **the permission set can be configured before the
invite is accepted**. The person lands in an account that already has exactly
the access they should have, and you never have a window where a new member is
sitting there with nothing or, worse, with too much. One asymmetry to know:
groups can be added to a pending invite but not removed from one — to take a
pre-assigned group back off, revoke the invite and send a fresh one.

Pending invites are listed with their assigned groups and an expiry date, and
each row offers two actions:

- **Resend invitation** — re-sends the mail. Resending is cooldown-guarded
  (5 minutes by default, `INVITE_RESEND_COOLDOWN_MINUTES`), so hammering the
  button will not send a burst of mails.
- **Revoke invitation** — invalidates the link.

Invites expire after 7 days by default (`INVITE_TTL_DAYS`).

The invitee opens the link, sees which organization they are joining, sets a
**display name** and a **password**, and is dropped straight into a session. An
expired or already-used link shows an invalid-invitation message with a way back
to sign-in.

## Resource grants

A grant gives a user or a group access to one workspace, project or service.
Grants are managed from the **Users** tab of the resource itself — visible to
people with write access on it — with two columns, one for groups and one for
members. Add a principal from the picker and the grant is created at **Read**;
raise it to Write with the level select on the row, or remove it entirely.

Two rules govern what a grant does:

- **Grants cascade.** A grant on a resource extends to everything inside it. A
  Read grant on a workspace covers its projects and their services, including
  ones added later.
- **Write on a resource** = organization `workspaces` Write **or** a Write-level
  grant on that resource **or** on any of its ancestors.

That second rule is what the app checks before showing you a resource's Users,
Settings and Usage tabs, before letting you rename or delete it, and before
letting you edit its variables.

### Owners should still be granted resources

Owners and `workspaces`-Write holders bypass grants for *access* — they can
already see and edit everything. It is therefore tempting to conclude that
granting them a resource is pointless. It is not, and this trips people up:

!!! important "Grants drive notification eligibility"
    **Only grant holders are notified.** Notification recipients are computed
    from explicit grants, and owners without a grant are deliberately *not*
    covered. The same rule governs the silence bell: it only appears on
    resources where you hold an explicit grant, because with no grant there are
    no notifications to silence.

    An owner who wants alerts for a service must hold a grant on it — or on one
    of its ancestors — like anybody else. See [Notifications](notifications.md)
    and [Silences & Quiet Hours](silences.md).

This also explains a subtlety in the bell's behaviour: if an ancestor is
silenced, the bell on a descendant shows as silenced and locked — *unless* you
hold an explicit grant on that descendant, in which case the broader silence
does not cover you and the bell stays independent. Most specific grant wins,
which is the same rule the dispatcher applies when deciding who to notify.

## Transferring ownership

Ownership transfer lives in the danger zone of **Settings → General** and is
visible only to the current owner. Pick an active member as the new owner and
re-confirm your identity — your current password, plus a code from your
authenticator if you have two-factor enabled.

You keep your membership and your permissions; you lose owner status.

!!! danger "Irreversible for you"
    Once transferred, you cannot take ownership back. Only the new owner can
    transfer it onward — including back to you, if they choose. Confirm you are
    handing it to the right person before you confirm.

## Requiring two-factor authentication

**Settings → General → Security** has a *Require two-factor authentication*
toggle. Turning it on takes effect immediately: every member without 2FA is
blocked — existing sessions included — until they enrol, and they are walked
through enrolment at the login screen. Nobody's account is lost, but nobody
proceeds without an authenticator from that moment on.

See [Your Account](account.md) for what enrolment looks like from the member's
side, including recovery codes.

## Audit log

The audit log records who did what. It is a table of **Time**, **Actor**,
**Action** and **Entity**, where actions taken by the platform itself rather
than a person are attributed to **System**. Rows expand to a detail view
carrying the change payload, or a note that no additional detail was recorded.

Three filters narrow it down: **Action** (free text — type `delete` to see every
deletion), **Entity type**, and **Actor**.

What makes it more than a compliance checkbox is that entries record **diffs**,
not just event names. In particular, **probe script changes are recorded as
unified diffs** and rendered as a coloured line diff in the detail view. That
means the audit log doubles as reviewable history for your probe scripts: when a
service starts failing after an edit, you can see the exact lines that changed
and who changed them. See [Writing Probes](writing-probes.md) for the scripts
themselves.

## Warning log

**Settings → Warning log** is the full history of platform warnings — probing
capacity and probe agent health. Banners elsewhere in the app show only the
latest episode of each type; this is the complete record.

| Column | Meaning |
|---|---|
| **Severity** | Warning or Error |
| **Warning** | The type — probing capacity exceeded, probe agent down, probe agent degraded |
| **Subject** | What it concerns, such as the agent involved |
| **First seen** | When the episode started |
| **Last seen** | When it was last observed |

The first-seen/last-seen pair is the point of the log. A capacity warning that
fires for ninety seconds during a deploy and a capacity warning that has been
open for three days look identical as a banner and are completely different
problems. Recurring entries of the same type are the signal to add a probe
agent, increase the available resources, or reduce probe frequency.
