---
description: "Tracedown's built-in CA signs every probe agent certificate for scheduler mTLS. Where the RSA-4096 root key lives, how rotation works, and what losing it costs."
---
# Certificate Authority

Tracedown runs its own internal certificate authority. Every probe agent holds a
certificate signed by it, and the scheduler mints itself a client certificate
from it at startup, so the CA is what makes mutual TLS between scheduler and
agents possible without you operating PKI by hand.

There is nothing to install and nothing to configure. The CA creates itself the
first time you enrol an agent, and its lifecycle is driven by the same
`PLATFORM_AES_KEY` that protects the rest of your secrets. What you do need to
understand is where the key lives, why two services must share it, and what a
rotation actually costs.

## Where the CA lives

The root certificate and its private key are rows in the `ca_root` Postgres
table. The private key is never written to disk in the clear: it is encrypted
with AES-256-GCM (128-bit tag, 12-byte IV) under `PLATFORM_AES_KEY`, and only
decrypted in memory at the moment a certificate needs signing.

Storing the CA in the database rather than on a filesystem is what lets you run
multiple gateway and scheduler replicas without distributing key material to
each host. It also means your CA is inside your normal database backups — and
that it is only as safe as your database and your encryption key together.

| Property | Value |
|---|---|
| Storage | `ca_root` table |
| Key encryption | AES-256-GCM under `PLATFORM_AES_KEY` |
| CA key size | RSA-4096 |
| CA validity | 10 years |
| Agent certificate validity | 365 days |
| Agent renewal threshold | 30 days before expiry |
| Scheduler client certificate | RSA-2048, 30 days, ephemeral |

## Creation

The CA is created by `CaService.ensureCaRoot()`, which runs whenever a
bootstrap token is minted — by `--agent-bootstrap` on the CLI or by the
dashboard's connect-agent flow. That call is idempotent: it returns the active
CA's certificate if one exists and creates one only if none does. The first
bootstrap token you ever mint is therefore also the moment your CA comes into
existence.

This ordering has a consequence for startup. The scheduler cannot boot without a
CA — it needs one to sign its own client certificate — but the CA is created by
minting a token, not by any service's startup path. That is why the Compose
stack has a dedicated `tracedown-ca-init` step that runs
`./bin/api-gateway --agent-bootstrap dev-agent` to completion before the gateway
and scheduler start. Its real job is not the token; it is forcing the CA into
existence. See [Quickstart](../install/quickstart.md).

If a certificate signing request arrives with no active CA, signing fails with:

```
CA root not initialized — run --agent-bootstrap first
```

The scheduler reports the same condition at startup as `CA root not found — run
--agent-bootstrap on the gateway first`.

## The scheduler's ephemeral certificate

The scheduler does not persist a certificate. On every startup it reads the
active CA from the database, decrypts the CA private key, generates a fresh
RSA-2048 keypair, and signs itself a client certificate valid for 30 days
(`CN=tracedown-scheduler,O=Tracedown`). Nothing is written back.

This is a deliberate simplification: a certificate that lives only in memory and
only as long as the process cannot leak from disk, cannot go stale, and needs no
renewal logic. Restarting the scheduler is the renewal mechanism, and 30 days is
simply longer than any scheduler process is expected to live.

!!! warning "The scheduler and gateway must share the exact same `PLATFORM_AES_KEY`"
    The scheduler decrypts the CA private key itself. If its key does not match
    the one the gateway used to encrypt the CA, decryption fails and the
    scheduler cannot start — it never gets a client certificate, so it can never
    dial an agent. Two services, one key, byte for byte. See
    [Secrets & Encryption](secrets.md).

The scheduler also loads **every non-expired** CA certificate as its trust
bundle, not just the active one. That is what makes rotation survivable.

## Rotation is make-before-break

`CaService.rotateCa()` implements rotation in two steps:

1. The current active CA row is stamped with `rotatedAt`. This retires it **as a
   signer** — it will not sign anything again — but it stays in the trust bundle
   until its `expiresAt` passes.
2. A fresh CA is created with no `rotatedAt`. It becomes the active CA and signs
   everything from that moment on.

Two selection rules follow from this, and they are the whole model:

| Concept | Rule |
|---|---|
| **Active CA** (the signer) | The newest row with `rotatedAt = NULL` |
| **Trust bundle** (who is believed) | Every row whose `expiresAt` is in the future |

`caBundle()` returns the trust bundle PEM-concatenated, and it is what gets
handed to agents — at registration as `caRootPem`, and again on every renewal.
So during a rotation overlap, an agent still holding a certificate from the old
CA is trusted by the scheduler (which trusts all non-expired CAs), and an agent
that has just renewed onto the new CA still trusts the scheduler's old-CA
certificate until the scheduler restarts. Nobody has to be updated in lockstep,
and no window exists where a working peer stops verifying. Agents migrate onto
the new CA naturally, one at a time, as they re-issue.

!!! danger "There is no rotation command"
    `rotateCa()` is reachable only from application code. There is currently no
    CLI flag, no admin endpoint, and no scheduled job that calls it. Rotating
    today means invoking it from application code against your database.

    Do not go looking for a `--rotate-ca` flag; it does not exist. Automation —
    a rotation job, a forced-renewal wave to drain the old CA early, an
    operator-triggered rotation from the dashboard — is not built yet.

## What a rotation costs in wall-clock time

Agent certificates last 365 days and agents renew when they are within 30 days
of expiry, checking every 24 hours. Rotation does not push anything to agents; it
only changes which CA signs the *next* certificate each agent asks for.

So an agent that renewed the day before you rotate will keep its old-CA
certificate for another 335 days before it asks for a new one. A rotation only
fully drains once every agent in the fleet has passed through its own renewal
window — up to 335 days after you rotate, in the worst case, with no way to hurry
it along short of re-bootstrapping the agent.

For that entire window the old CA must remain non-expired, or the agents still
holding its certificates drop out of the trust bundle and the scheduler stops
verifying them. The 10-year CA validity covers a 335-day drain many times over,
which is precisely why it is 10 years and not 1. Plan rotations as a year-long
background migration, not an afternoon.

## Losing the encryption key

!!! danger "`PLATFORM_AES_KEY` is not recoverable and the CA is not recoverable without it"
    The CA private key exists only as AES-256-GCM ciphertext in `ca_root`. Lose
    the key and that ciphertext is undecryptable — there is no escrow, no
    recovery path, and no way to derive it from the certificate.

    The blast radius: the gateway can no longer sign CSRs, so no agent can
    register or renew. The scheduler can no longer decrypt the CA key, so it
    cannot mint its client certificate and will not start. Every existing agent
    certificate remains valid on paper and useless in practice, because the peer
    that has to verify it is down. Recovery means creating a new CA and
    re-bootstrapping **every agent** with a fresh token.

Treat `PLATFORM_AES_KEY` as the most important string in your deployment and
back it up somewhere other than the database it protects — a database backup
alone restores nothing. See [Secrets & Encryption](secrets.md) and
[Backup & Restore](backup.md).

## Related

- [Probe Agents](../install/agents.md) — bootstrap, renewal, and the agent side
  of mTLS.
- [Secrets & Encryption](secrets.md) — what `PLATFORM_AES_KEY` protects.
- [Backup & Restore](backup.md) — keeping the CA and its key recoverable.
