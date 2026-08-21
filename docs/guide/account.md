---
description: "Your Tracedown account: profile and display name, changing your email and password, two-factor authentication, active sessions, silences and quiet hours."
---
# Your Account

Everything that belongs to you rather than to the organization lives under **My
account**. It has three tabs:

| Tab | What it holds |
|---|---|
| **Profile** | Display name, email, password, two-factor authentication |
| **Sessions** | The devices currently signed in as you |
| **Silences** | Resources you have muted, and your quiet hours |

Nothing here is visible to other members' accounts, and nothing here requires a
permission — every member has the same three tabs.

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
your password, and — if you have not already — enable two-factor.

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
