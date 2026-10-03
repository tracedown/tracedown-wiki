---
description: "Your Tracedown account: profile and display name, changing your email and password, two-factor authentication, active sessions, silences and quiet hours, and your API keys."
---
# Your Account

Everything that belongs to you rather than to the organization lives under **My
account**. It has four tabs:

| Tab | What it holds |
|---|---|
| **Profile** | Display name, email, password, two-factor authentication |
| **Sessions** | The devices currently signed in as you |
| **Silences** | Resources you have muted, and your quiet hours |
| **API keys** | The keys that let a script or a tool call the API as you |

Nothing here requires a permission — every member has the same four tabs.
Other members cannot see any of it, except your API keys — see
[API key oversight](users-and-permissions.md#api-key-oversight).

## Profile

The Profile tab shows your current **email** and lets you edit your **display
name**. The display name is what other members see next to your actions in the
members list and the [audit log](users-and-permissions.md#audit-log), so it is
worth making it recognisable. The tab also carries a **data export** section,
which hands you a copy of your account's data.

Display-name editing can be switched off for the whole platform. When it is, the
field is disabled and the app tells you that profile editing is disabled and to
ask an administrator. This is normal on installations that source identity from
somewhere else — it is not a fault. The switch covers the display name only —
email and password changes stay available — and members holding org **Users**
write bypass it.

### Changing your email

The email form asks you to re-confirm your identity: your password, plus a code
from your authenticator if you have two-factor enabled. A successful change
signs out your other sessions — whoever else might be holding a session does
not get to keep it across an identity change.

### Changing your password

The password form sits below the profile section and asks for your **current
password** alongside the new one, entered twice. Requiring the current password
is what stops someone who finds an unlocked laptop from silently taking the
account over — it means an attacker needs the password they are trying to
replace.

### Resetting a forgotten password

If you cannot sign in, the login screen offers **Forgot your password?**. You
enter your account email, a reset link is sent, and the link takes you to a page
where you choose a new password. Afterwards you sign in with it as usual.

!!! note "The confirmation message is intentionally vague"
    The response is always *"If an account exists for that address, a reset link
    is on its way"* — whether or not an account exists. This is deliberate: a
    reset form that says "no such user" is an oracle for testing which email
    addresses have accounts on your installation. Do not read the message as
    confirmation that the mail is coming; if it does not arrive, check the
    address and ask an administrator.

### Two-factor authentication

Two-factor authentication (TOTP) binds sign-in to an authenticator app, so a
leaked password on its own is not enough to get in.

Enrolment runs in three steps from the Profile tab:

1. **Enable 2FA.** Tracedown generates your secret.
2. **Scan and confirm.** Scan the QR code with your authenticator app, or enter
   the **setup key** by hand if you cannot scan it, then type the **6-digit
   code** to prove the app is working. Enrolment does not complete until a code
   verifies — you cannot lock yourself out with a mis-scanned code.
3. **Save your recovery codes.** You are shown a set of one-time recovery codes.

!!! warning "Recovery codes are shown once"
    Each recovery code works exactly once, and they are not shown again after
    you dismiss the screen. Store them somewhere you can reach **without** the
    authenticator — a password manager on a different device, or paper. Their
    entire purpose is to work when the phone with your authenticator on it is
    lost, wiped, or in the sea.

At sign-in you enter a code from your authenticator, or choose **Use a recovery
code instead** and spend one of your codes. Recovery codes are accepted anywhere
an authenticator code is. If you run low, the Profile tab can **regenerate**
them — a fresh set that replaces every remaining old code.

**Disabling** two-factor requires a current TOTP code or a recovery code — the
same proof as signing in. Knowing the password is not sufficient to strip 2FA
off the account.

If your organization requires two-factor, you are made to enrol at your next
sign-in before you can continue, and the app says so. You do not need to visit
this tab first; the enrolment flow is the same three steps. See
[Users & Permissions](users-and-permissions.md#requiring-two-factor-authentication)
for the organization-wide toggle.

## Sessions

The Sessions tab lists the devices currently signed in to your account, each
with its **device**, **IP address**, and **last active** time. Your current
device is marked **This device** and has no revoke button — you cannot sign
yourself out from underneath yourself; use the normal sign-out for that.

Two actions are available:

- **Revoke session** on any other row, ending that one session.
- **Sign out other sessions**, which ends every session except the one you are
  using.

The advice in the app is *"Revoke any you don't recognize"*, and it is worth
taking literally. This tab is how you find out that a session is running from an
IP you have never been near. If that happens, sign out other sessions, change
your password, and — if you have not already — enable two-factor. Then check
**API keys** for any key you did not create, and revoke it.

Signing out other sessions is also the right reflex after any password change
you made because you suspected a problem: changing a password is not by itself a
reason for existing sessions to disappear.

## Silences

The Silences tab lists the resources you have muted — the **Muted resources**
section — and is where your **quiet hours** live.

Silences are yours alone, scoped to the organization you set them in: muting a
service stops *you* being notified about it and has no effect on anyone else,
and if you belong to several organizations, each keeps its own silences and
quiet hours. You create them with the
bell icons around the app rather than here; this tab is the inventory and the
place to lift them. If it is empty, the app points you at the bells.

**Quiet hours** are a daily window during which no notifications are sent to
you, in a timezone you choose. Overnight windows such as 22:00–07:00 are
supported, so you do not have to express "overnight" as two ranges.

Both are covered properly in [Silences & Quiet Hours](silences.md), including
how a silence on a parent resource interacts with grants further down — see also
[Notifications](notifications.md) for who gets notified in the first place.

## API keys

An API key lets a script, a pipeline or an agent call the
[Tracedown API](api.md) as you. Each key works in a single organization and can
never do more than you can there; it stops working the moment you could no
longer act in that organization yourself. The tab lists your keys in every
organization, including ones you have since left: those keys are revoked, and
still count towards your limit until you delete them. Each row shows the key's
organization, name, first characters, access level, state, last use and
expiry.

### Creating a key

**New API key** opens a short form:

- **Name** — what the key is for, up to 128 characters (`ci-deploy`, say).
- **Access** — **Read** (GET and HEAD requests only, within what you can see)
  or **Read and write** (everything you can do in this organization). Read is
  the default; choose write only for a key that has to change things.
- **Expires** — **Never**, **In 30 days**, **In 90 days**, **In a year**, or
  **Custom**: a whole number of days from 1 to 3650.
- **Current password**, and a **Two-factor code** if you have two-factor
  enabled — a code from your authenticator app, or one of your recovery codes.

The key acts in the organization you are signed in to, and the form names it.
To create one for another organization, switch organizations, then open
**My account → API keys** again.

Asking for the password again is deliberate. A key outlives the session it was
made in — a password change does not revoke it — so a session alone must not be
enough to leave one behind. Creating a key shares the sign-in rate limit, and a
wrong two-factor code counts towards the same lockout as one at sign-in.

!!! warning "The key is shown once"
    The new key appears once, right after it is created, together with the base
    URL to call and a link to the API description. Copy it and store it
    somewhere safe: the dialog does not close until you confirm you have.
    Tracedown keeps only a digest of the key, so once the dialog closes nobody
    can see it, you included. A key you lost is a key to revoke and replace.

You can hold up to 20 keys across all of your organizations — the operator can
change the number. **Every key in your list counts**, revoked and expired ones
included, until you delete it; if you reach the limit, delete the keys you no
longer need.

### Key states

| State | What it means |
|---|---|
| **Active** | Accepted, within its access level. You must be enrolled in two-factor authentication while the organization, or a group you belong to, requires it, or the key is refused. |
| **Revoked** | Refused for good. A revoked key cannot be restored. Create a new key to continue. |
| **Expired** | Past its expiry date, and refused. Create a new key to continue. |
| **Inactive** | You cannot currently act in this organization — your access there has been disabled, for instance — so the key is refused until you can again. |

If the organization you are signed in to, or a group you belong to, requires
two-factor sign-in and you have not enrolled, the tab says so above the list:
your keys there still read **Active**, and every request with one is refused
with `totp_enrollment_required` until you enrol.

### Revoking and deleting

Each row has two actions, both hold-to-confirm (hold the button for three
seconds):

- **Revoke** stops the key at once, for good. The row stays in your list,
  marked **Revoked**, so you can still see when it was last used; a revoked
  row no longer offers Revoke.
- **Delete** removes the key from the list and frees its place under the
  limit. A deleted key is revoked as well.

Revoke a key the moment you suspect it has leaked; delete it once you no longer
need to see it. Who else can do either is under
[API key oversight](users-and-permissions.md#api-key-oversight).

### What a key survives, and what it does not

A key is a credential of its own, not a session, so what ends your sessions
leaves it alone:

- **Changing your password**, or resetting a forgotten one, does not affect
  your keys.
- **Changing your email** does not affect them.
- **Signing out other sessions** does not affect them.

That is why a leaked key is something you revoke here; a password change does
not clean it up.

A key stops working when you can no longer act in its organization:

- **Being removed from the organization** revokes every key you held there.
  Being invited back later does not bring them back.
- **Your access being disabled**, in the organization or on the whole platform,
  makes your keys **Inactive** until it is enabled again.
- **Closing or deleting your account** revokes every key you hold; keys in
  organizations you own go with those organizations.
- **The organization, or a group you belong to, requiring two-factor
  authentication** refuses your keys there with `totp_enrollment_required`
  until you enrol — exactly as it holds up your sign-in.

And because a key holds no permissions of its own, a permission you lose is
lost to your keys on their very next request. There is nothing on the key to
update.
