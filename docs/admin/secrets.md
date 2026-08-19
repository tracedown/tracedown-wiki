# Secrets & Encryption

Tracedown holds credentials on your behalf. Probe variables contain the API
keys and passwords your probes authenticate with, TOTP secrets protect your
users' logins, and the certificate authority's private key is what makes agent
mTLS mean anything. All of it is encrypted at rest with a single key you
supply, and the security of the whole installation reduces to how you handle
that key.

## The threat model in one paragraph

Everything sensitive in the database is encrypted with `PLATFORM_AES_KEY`, and
the key is never stored in the database. That cuts both ways, and the second
half is the part people miss. A stolen database backup is useless to an
attacker who does not have the key — and it is equally useless to *you* if you
do not have the key. A backup and the key it needs are two halves of one
artifact. Store them in the same place and you have encrypted nothing; lose one
of them and you have backed up nothing. [Backup & Restore](backup.md) covers
the mechanics.

## The secrets

| Secret | Format | Protects |
|---|---|---|
| `PLATFORM_AES_KEY` | Exactly 64 hex characters (256 bits) | CA root private key, per-org data-encryption keys (and through them all secret variables), non-secret encrypted variables, TOTP secrets, domain-verification HMAC |
| `JWT_SECRET` | Free-form string | Reserved for token signing — see below |
| `DATABASE_PASSWORD` | Free-form string | PostgreSQL authentication |
| Email provider credentials | Provider-issued | Outbound mail |
| Object store credentials | Provider-issued | Saved response bodies |
| Agent bootstrap token | 64 hex characters, generated | One-time agent enrolment |

### PLATFORM_AES_KEY

This is the one that matters. It is the AES-256 key used to encrypt:

- the CA root private key at rest, in the `ca_root` table;
- every organization's data-encryption key (DEK) in `org_encryption_keys` —
  the key that in turn encrypts the org's **secret** variables (see
  [Envelope encryption for secret variables](#envelope-encryption-for-secret-variables));
- non-secret encrypted variables (the "Variable" type) directly;
- TOTP secrets.

It is also the HMAC-SHA256 key for domain-verification challenges.

The length is enforced at runtime, not merely documented:

```kotlin
require(aesKeyHex.length == 64) { "AES key must be 64 hex characters (256 bits)" }
```

A key of any other length fails fast at startup rather than silently degrading.
The default is 64 zeros, which is valid hex and therefore starts cleanly — that
is exactly why you have to set it deliberately.

!!! warning "Three services must share the same value"
    `PLATFORM_AES_KEY` is read by **api-gateway**, **probe-scheduler**, and
    **notification-dispatcher**. All three must be given the identical value.

    The gateway encrypts variables; the scheduler decrypts them to resolve them
    for a probe run and decrypts the CA key to mint its own client certificate;
    the dispatcher decrypts org variables referenced from webhook URLs. If the
    three disagree, the scheduler **fails at startup** — it cannot decrypt the
    CA key — while the gateway and dispatcher fail at run time, on the first
    decryption they attempt.

The `--agent-bootstrap` CLI refuses to run at all when `PLATFORM_AES_KEY` is
unset, so a bootstrap token cannot be minted under an accidental default key.

!!! note "Production refuses the defaults"
    With `DEPLOYMENT_ENV=production`, a service given the all-zero
    `PLATFORM_AES_KEY` (or the gateway given the default `JWT_SECRET`) refuses
    to start rather than running on published secrets. `ALLOW_INSECURE_DEV_KEYS=true`
    overrides the guard; it exists for test rigs, not for production.

### JWT_SECRET

Despite the name, sessions are **not** JWTs. A session token is 32 bytes from a
secure random generator, handed to the browser opaque and stored server-side
only as a SHA-256 hash in the `sessions` table; validating a request is a
database lookup, not a signature check. `JWT_SECRET` is read by the gateway and
guarded against its dev default in production, but nothing currently signs with
it — it is reserved.

Two consequences follow. Knowing the default value does not let anyone forge a
session. And changing `JWT_SECRET` does **not** log anybody out — revoking
sessions means deleting session rows (each user can do this from
**Account → Sessions**), not rotating this value.

### Database and provider credentials

`DATABASE_PASSWORD` authenticates to PostgreSQL. The remaining credentials are
ordinary provider secrets, but note that the two mail-sending services use
different variable names for the same underlying thing:

| Purpose | api-gateway | email-service |
|---|---|---|
| Resend API key | `RESEND_API_KEY` | `EMAIL_RESEND_API_KEY` |
| Mailgun API key | `MAILGUN_API_KEY` | `EMAIL_MAILGUN_API_KEY` |
| SMTP password | `SMTP_PASSWORD` | `EMAIL_SMTP_PASSWORD` |

Setting the gateway's name on the email-service (or the reverse) leaves the
provider unconfigured, and mail fails at send time rather than at boot.

Body object storage is likewise split by consumer, because the components talk
to the store for different reasons — the agent writes bodies, the
result-ingestor relocates them as results land, and the aggregate-worker
deletes them at retention:

| Component | Variables |
|---|---|
| aggregate-worker | `STORAGE_S3_ACCESS_KEY`, `STORAGE_S3_SECRET_KEY` |
| result-ingestor | `STORAGE_S3_ACCESS_KEY`, `STORAGE_S3_SECRET_KEY` |
| probe agent | `PROBE_AGENT_S3_ACCESS_KEY_ID`, `PROBE_AGENT_S3_SECRET_ACCESS_KEY` |

### Agent bootstrap tokens

A bootstrap token is 64 hex characters, stored as a bcrypt hash at cost 12,
valid for **1 hour**, and single use. The short TTL and single use are the
point: the token is a bearer credential that trades itself for a client
certificate, so its window of usefulness to an attacker is deliberately about
as long as it takes you to paste it into an agent's environment. See
[Probe Agents](../install/agents.md) and
[Certificate Authority](certificate-authority.md).

## The shipped development values

The Compose stack in `docker/` ships with working secrets so that
`docker compose up` produces a running system. Every one of them is in the
repository and therefore known to everyone.

| Variable | Shipped value | Where |
|---|---|---|
| `PLATFORM_AES_KEY` | `0123456789abcdef…` (repeating) | `docker/.env.example` → your `.env` |
| `JWT_SECRET` | `dev-jwt-secret-change-me-for-prod` | `docker/.env.example` → your `.env` |
| `DB_PASSWORD` | `tracedown` | `docker/.env.example` → your `.env` |
| `DEMO_USER_PASSWORD` | `Down2trace!` | `docker/docker-compose.yml` |

!!! danger "Rotate all four before the install is reachable by anyone else"
    These are fine for a laptop trial and unacceptable for anything on a
    network. `DEMO_USER_PASSWORD` is set in `docker-compose.yml` rather than
    `.env` — editing `.env` alone leaves the demo administrator's password at
    a published value.

## Generating real values

=== "PLATFORM_AES_KEY"

    ```bash
    openssl rand -hex 32
    ```

    The key must be 64 hex characters. Each byte is two hex characters, so 32
    random bytes render as exactly 64 characters — which is the 256 bits
    AES-256 requires. `openssl rand -hex 64` would give you 128 characters and
    fail the length check at startup.

=== "JWT_SECRET"

    ```bash
    openssl rand -base64 48
    ```

    Free-form, so length is the only real constraint. 48 bytes of entropy is
    comfortably beyond what any future signing use would need — and the
    production guard refuses the shipped default either way.

## Envelope encryption for secret variables

Secret variables — the (secret, write-only) type across all four scopes: org,
workspace, project and service — are not encrypted with `PLATFORM_AES_KEY`
directly. They use per-organization envelope encryption:

- Each organization owns a random AES-256 **data-encryption key (DEK)**,
  minted when the organization is created. The DEK is stored in the
  `org_encryption_keys` table, wrapped with `PLATFORM_AES_KEY` acting as the
  **key-encryption key (KEK)**. The DEK never exists unwrapped outside process
  memory.
- Secret values are encrypted AES-256-GCM under the org DEK. The ciphertext
  is authenticated and bound to its context (org id, scope, variable key), so
  a ciphertext cannot be moved to another org, scope or variable and still
  decrypt. Stored values carry a `v2:` prefix; the old format (no prefix) is
  the pre-envelope platform-key encryption and remains readable.
- Non-secret variables are unchanged: the "Variable" type is encrypted with
  the platform key as before, metrics are plaintext. TOTP secrets and the CA
  root key are also unchanged.

Nothing about key distribution changes for you: the gateway, scheduler and
dispatcher still need only `PLATFORM_AES_KEY`. They fetch and unwrap the org
DEK from the database on demand.

### Upgrading an existing installation

No manual migration is needed. On the first gateway start after the upgrade,
a background pass finds every secret still in the old format, decrypts it with
the platform key and re-encrypts it under the owning org's DEK. The pass is
idempotent (it re-runs harmlessly on every start), converts what it can, and
logs any row it cannot convert without blocking startup. Organizations created
before the feature get their DEK minted automatically — at that first
re-encryption, or lazily on their next secret write.

### Crypto-shredding on organization erasure

When an organization is purged (hard-deleted after the soft-delete window),
the purge job deletes the org's `org_encryption_keys` row **first**, before
any data rows, in its own transaction. From that moment every secret
ciphertext of that organization is permanently undecryptable — even if a later
purge step fails and leaves rows behind until the next run, the secrets in
them are already unreadable. Erasure of the org's secrets does not depend on
every row actually being reached.

!!! warning "Backups are outside the shred"
    Crypto-shredding acts on the live database. A backup taken *before* the
    purge still contains both the wrapped DEK and the ciphertexts, and the
    platform key can unwrap that DEK — so the secrets in old backups remain
    recoverable until those backups age out of your retention. If erasure
    guarantees matter to you, your backup retention window is part of the
    guarantee. See [Backup & Restore](backup.md).

### Rotating the platform key for org DEKs

`--rewrap-org-keys` re-wraps every org DEK from an old platform key to a new
one. The DEKs themselves do not change, so secret ciphertexts stay valid and
nothing is bulk re-encrypted:

```bash
PLATFORM_AES_KEY=<new key> PLATFORM_AES_KEY_OLD=<old key> \
  java -jar api-gateway.jar --rewrap-org-keys
```

It is idempotent — rows already wrapped with the new key are skipped, so it is
safe to re-run after a partial failure. **This rotates only the DEK wrapping.**
It does not touch the other users of the platform key (TOTP secrets, the CA
root key, non-secret encrypted variables), which is why the section below
still applies to the key as a whole. Note also that backups made before a
rotation contain DEKs wrapped with the old key — the old key is only fully
retired once those backups are gone.

## PLATFORM_AES_KEY cannot (yet) be fully rotated

!!! danger "Re-encryption tooling covers org DEKs only. Treat the key as permanent."
    Beyond `--rewrap-org-keys` (above), no supplied command re-encrypts
    existing data under a new key. Changing `PLATFORM_AES_KEY` on an
    installation that already holds data does not migrate the rest — it
    orphans it:

    - every non-secret encrypted variable becomes undecryptable, so probes
      that depend on them fail;
    - every TOTP secret becomes undecryptable, so users with 2FA cannot log in;
    - the CA root private key becomes undecryptable, so the scheduler cannot
      sign agent certificates and mTLS dispatch stops;
    - every org DEK you did **not** re-wrap becomes undecryptable, taking all
      of that org's secret variables with it.

    There is no recovery path other than restoring the old key.

This is a real constraint and it is stated plainly here rather than dressed up
with a procedure that does not exist. The practical consequences:

- **Choose the key once, before first boot.** Generate it with
  `openssl rand -hex 32` and set it everywhere before you create any data.
- **Back it up separately from the database**, somewhere durable — a password
  manager, a secrets manager, an offline copy. See [Backup & Restore](backup.md).
- **Treat it as permanent for the life of the installation.** If it is ever
  exposed, the honest remedy is a new installation and re-entering the
  variables, not a key change.

Should you need to re-key in practice, the only route is to rebuild: stand up a
fresh installation with the new key and re-enter every variable and TOTP
enrolment by hand. Plan as though that is not available to you.

## Related

- [Configuration](../install/configuration.md) — the full environment reference.
- [Certificate Authority](certificate-authority.md) — what the CA key protects.
- [Backup & Restore](backup.md) — keeping the key and the data separately.
- [Troubleshooting](troubleshooting.md) — symptoms of a key mismatch.
