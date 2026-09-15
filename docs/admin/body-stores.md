---
description: "Body stores let agents keep saved response bodies somewhere other than the platform's own storage - import and in_place modes, S3 permissions, filesystem mounts, private endpoints and the error codes."
---
# Body Stores

By default every probe agent writes saved response bodies into one place: the
`STORAGE_*` location the stack itself is configured with. That is the right
arrangement for a single-site install, and it is what happens if you never read
this page.

It stops being right the moment agents are somewhere the platform's storage is
not. An agent in another network cannot reach the bucket. An agent probing from
a jurisdiction whose data has to stay there must not write to a bucket
elsewhere. A **body store** is the answer to both: a second location, described
once in Tracedown, that named agents write their bodies to instead.

## What a store is

A store is a row you create under **Settings → Body storage**. It names a
location — an S3-compatible bucket and prefix, or a directory — and the
credentials to use with it, and it carries a **mode** that decides what the
platform does with bodies found there. Agents are then pointed at it
individually.

Nothing about stores is on by default. An install with no stores behaves
exactly as it did before they existed.

### The default store

The location the stack is configured with — `STORAGE_S3_ENDPOINT` and friends,
or `STORAGE_FILESYSTEM_ROOT` — is the **default store**. It is not a row and
you do not manage it here; the dashboard shows it read-only so you can see what
an unassigned agent is writing to. Every agent uses it until you say otherwise,
and pointing an agent back at it is how you undo an assignment.

Bodies in the default store are the platform's own: the aggregate-worker
deletes them on the retention windows in
[Retention & Aggregation](retention.md).

## The two modes

Every store is one of two modes, and the mode is the whole decision — it
settles who owns the bodies, which service has to reach the store, and what
permissions its credentials need. Choose it when you create the store; there is
no good reason to change it under a store that already holds bodies.

| Mode | The rule in one line |
|---|---|
| `import` | The agent writes here, and the platform moves the body into the default store as the result lands. |
| `in_place` | The body stays here, and the platform reads it on demand and never deletes it. |

`import` is a staging area. Use it when the reason for the store is that the
*agent* cannot reach the platform's storage — the body ends up where it always
did, on the platform's retention, and the store holds it only for the seconds
between the probe and the result being ingested.

`in_place` is ownership. Use it when the reason for the store is that the
*bodies* must live somewhere specific — a bucket you keep, in a region you
chose, on a retention you set. Tracedown records where each body is and fetches
it when someone opens the result. It never writes to and never deletes from an
`in_place` store.

!!! warning "`in_place` bodies are yours to clean up"
    The platform deletes the database rows on the usual retention schedule and
    leaves the objects alone. Nothing in Tracedown will ever empty an
    `in_place` store — that is what the mode means. Put a lifecycle rule on the
    bucket, or a cleanup job on the directory. See
    [Retention & Aggregation](retention.md#body-storage).

## What each mode needs from the store

The two modes are reached by different services, for different reasons, and the
permissions follow from that.

| | `import` | `in_place` |
|---|---|---|
| S3 permissions the store credentials need | Read **and delete** (`GetObject`, `DeleteObject`, plus `ListBucket` for the test probe) | Read only (`GetObject`, plus `ListBucket` for the test probe) |
| Which service dials the store | **result-ingestor** — it copies the body out and removes the source | **api-gateway** — it fetches the body when someone opens the result |
| Where the endpoint must be reachable from | The ingestor's network | The gateway's network |
| What the *agent's* own credentials need | Write (`PutObject`) | Write (`PutObject`) |

The agent's credentials are separate from the store's and you set them on the
agent, not here — see [the agent's storage
environment](../install/agents.md#the-agents-storage-environment).
Give the agent write access and nothing more; give the store the read (and, for
`import`, delete) access above. There is no reason for either to hold both.

!!! note "Test runs in the gateway"
    The **Test** button probes the store from the api-gateway, whichever mode
    the store is in. For an `in_place` store that is exactly the service that
    matters. For an `import` store it is not — a green test tells you the
    gateway can reach the endpoint, and the ingestor is the one that has to. If
    the two services sit on different networks, check the ingestor's logs after
    the first result rather than trusting the test.

## Filesystem stores

A store of kind `filesystem` is a directory rather than a bucket, and it is
usable only when every party can see the *same* directory:

- the **agent** writes bodies into it;
- the **api-gateway** reads them back (`in_place`), and runs the test probe;
- the **result-ingestor** reads and removes them (`import`).

A path that exists in only one of those containers is not a store, it is three
unrelated empty directories. Mount one volume into all of them.

The root a store may use is fenced by `BODY_STORE_FILESYSTEM_BASES`, a
comma-separated list of directories set on the gateway and the ingestor. A
store's root must be a directory **beneath** one of those bases — a base itself
is not accepted — and anything else is refused with `root_outside_bases`. The
variable has no default: leave it unset and filesystem stores cannot be created
at all, which is the right setting for any install that does not want them.

The shipped Compose stack mounts a `tracedown-stores` volume at `/data/stores`
on the gateway and the ingestor, and sets
`BODY_STORE_FILESYSTEM_BASES=/data/stores`. A store root of
`/data/stores/eu-west` is then valid, and the agent gets the same volume mounted
at the same path.

!!! warning "Filesystem stores need a shared volume, so hosted platforms cannot have them"
    On Railway, Fly, Kubernetes without a `ReadWriteMany` claim, or anywhere
    else the gateway, the ingestor and the agent run on hosts that share no
    disk, a filesystem store cannot work — and it will not fail loudly, it will
    simply never find the body. Use an S3-compatible store there. This is the
    ordinary case for an agent in another network, which is most of why stores
    exist.

## Private endpoints

A store endpoint is typed in by a person with settings access, and the gateway
and the ingestor then dial it with the store's credentials. Left unguarded that
is a way to make those services talk to your metadata service, your database,
or an internal admin port. So by default an endpoint must be:

- `https://`, with no path, no credentials and no query;
- a name that is not internal-only (`.internal`, `.local` and the like);
- a name that resolves to a public address — checked when the store is saved,
  again every time it resolves, and once more against the address actually
  connected to;
- a name with a dot in it, since a single-label host like `minio` means a
  different machine in every network.

That rules out a MinIO on your own private network, which is a legitimate thing
to want. Set `BODY_STORE_PRIVATE_ENDPOINTS=true` on **both** the gateway
and the ingestor and all four rules above are lifted: `http://` is accepted,
and private, CGNAT, loopback, link-local, internal-suffix and single-label hosts
are all allowed, at validation, at DNS resolution and at connect. Redirects are
still never followed and no proxy is used, so the address that was checked is
the only one the request reaches.

It is off by default, and it is a deployment-wide decision rather than a
per-store one: turning it on says that anything a settings-writer can type in
this installation may be dialled from inside your network. Turn it on for a
stack whose object store is on the same private network as the platform, and
leave it off otherwise. The shipped Compose stack sets it, because everything
in it is on one Docker network.

## Each agent writes under its own sub-prefix

Agents sharing a store do not share a key space. An agent writes under its own
slug:

- S3: `<prefix>/<agent-slug>/…`
- filesystem: `<root>/<agent-slug>/…`

and at ingest a body is accepted only if its path is inside that sub-prefix.
A body anywhere else in the store — including under another agent's slug — is
not recorded, and the step shows the reason `outsideAssignedStore`.

This is why an `import` store must have a non-empty prefix: the sub-prefix is
what keeps one agent from reading or deleting another's bodies, and it needs
something to hang off.

The dashboard's connect form prints the full value with the slug already
appended, so there is nothing to work out by hand.

## Stores belong to one organization

A store is created inside an organization and is visible, editable and
assignable only within it. Another organization's administrator cannot list it,
cannot repoint it, and cannot attach one of their agents to it — a store id from
elsewhere is simply `body_store_not_found`.

Agents, though, have no owner: any healthy agent can run any
organization's service unless the service restricts itself to a subset. That
leaves one case to get right on an install with several organizations.

!!! warning "Assign a store only to agents that serve its organization"
    When an agent assigned org A's store runs a probe for org B, the body is
    **not** recorded: there is no URL and the step carries the reason
    `storeOrgMismatch`. The result itself is fine — timings, assertions,
    status, all normal — it is only the saved body that is dropped, and the
    ingestor logs a WARN once per agent and organization.

    So on a multi-organization install, pair a store with agents that org has
    to itself, using the service-level
    [agent restriction](../install/agents.md#which-agents-run-a-service) to keep
    other organizations off them. On a single-organization install — the common
    case — the question does not arise.

## Assigning an agent

Set an agent's store from the store column in **Settings → Agents**, or choose
one in the connect form when you mint its bootstrap token. A token carries the
store, so an agent enrolled with it starts on the right store with no second
step.

!!! danger "Changing an existing agent's store means redeploying that agent"
    The assignment is a database row. It tells the platform where to *look*; it
    does not tell the running agent where to *write*, because the agent writes
    where its own environment says. Until you redeploy it with the new storage
    variables, it keeps writing to the old location and those bodies are
    refused at ingest with `outsideAssignedStore`.

    The dashboard shows the environment to apply when you change the
    assignment. Apply it, restart the agent, and the two agree again.

One move is safe without a redeploy: a body that lands inside the **default**
store is always relocated as it always was, whatever the agent is assigned. So
moving an agent to a store, or back off one, loses nothing on the default-store
side of the change.

## Changing a store

Name, endpoint, region and credentials can be edited at any time. The
**location** cannot, once the store holds bodies:

!!! note "The location locks as soon as a body is recorded in the store"
    While any stored body references the store, changing its `kind`, bucket,
    prefix or root path is refused with `body_store_location_locked`. Those
    four are how the platform finds the bodies it already recorded; repointing
    them would not move the objects, it would only make every existing body
    unreadable and point the store at somebody else's data.

    To move bodies to a new location, create a second store, reassign the
    agents to it, and keep the old one until its bodies have aged out — or
    [forget them](#deleting-a-store).

A new secret access key is required whenever the endpoint, the bucket or the
access key id changes; the save is refused with `store_field_required` and the
field `secretAccessKey` otherwise. Keeping a secret across a change of endpoint
would mean sending the old credentials to a new host.

Saving a store that fails validation returns `field_invalid` naming the field
and one of these reasons: `scheme_not_https`, `private_address`,
`internal_host`, `single_label_host`, `has_path`, `root_not_absolute`,
`root_outside_bases`, `overlaps_default`, `overlaps_store`, `invalid_bucket`,
`invalid_prefix`. The two overlap reasons are worth naming: a store may not sit
inside the default store's location, or inside another store's, because a body
in the overlap would belong to two stores with different rules.

## Deleting a store

Deleting a store is refused with `body_store_in_use` while an active agent, an
outstanding bootstrap token, or any stored body still names it. The error says
which of the three — a used or expired token and a decommissioned agent release
the store rather than blocking, so in practice the blocker is either a live
agent you should reassign first, or bodies.

Bodies are the hard case, because they age out only if a window says so, and
both windows can be switched off: `BODY_RETENTION_DAYS=-1` leaves a body to go
with its result, and `RESULT_RETENTION_DAYS=-1` means the result never goes
either. Which window applies depends on where the body ended up. A body an
`import` store handed over lives in the default store and expires on the body
window like any other body there. A body in an `in_place` store is outside both
windows — the platform never deletes from one — so an `in_place` store is
exactly the store whose bodies will still be blocking its deletion years from
now. The forcing form — **Delete and forget bodies** in the dashboard —
does the whole thing in one transaction: unassigns the store's agents, clears
it off outstanding tokens, clears the stored URL on every step that pointed into
it with the reason `storeRemoved`, and deletes the row. It is recorded in the
audit log with the counts.

!!! warning "Forgetting bodies does not delete them"
    The results keep their timings, assertions and status; only the body
    becomes unavailable, and the step says `storeRemoved`. The **objects are
    untouched** — they stay in a store Tracedown no longer holds credentials
    for. Empty the bucket or the directory yourself if that is what you meant.

## Store health

A store row carries its last failure — a code and a timestamp — set on any
failed read, import or test, and cleared on the next success. The store list
shows it. It is the quickest way to tell "this store has never worked" from
"this store broke on Tuesday", and it is worth a glance after any change to a
bucket policy or a network.

## Test result codes

**Test** is a read-only probe: it lists at most one key under the S3 prefix, or
checks that the filesystem root is a readable directory. It never writes.

| Code | What it means | What to do |
|---|---|---|
| `not_configured` | The store has no usable location — an S3 store with no bucket, or a filesystem store with no root. | Fill in the missing field. |
| `unreachable` / `blocked_endpoint` | DNS did not resolve, the connection failed, or the endpoint guard refused the address. | Check the endpoint is reachable from the gateway. If it is on a private network, see [Private endpoints](#private-endpoints). |
| `bucket_not_found` | The endpoint answered, and there is no such bucket. | Check the bucket name and the region — a bucket in another region reads as missing on some providers. |
| `invalid_credentials` | The access key id or the secret key is wrong. | Re-enter both. The secret is write-only, so re-saving it is the only way to correct it. |
| `access_denied` | The credentials are valid and the policy refuses the call. | Grant the permissions for the store's mode — read, plus delete for `import`, plus list for this probe. |
| `secret_undecryptable` | The stored secret cannot be decrypted with `BODY_STORE_AES_KEY`. | The key is missing or is not the one the secret was written under. Restore the key, or re-enter the secret to rewrite it under the current one. See [Secrets & Encryption](secrets.md#body_store_aes_key). |
| `unexpected_response` | Something answered, and it was not an S3 API. | Check the endpoint is the API host, not a console or a bucket-scoped URL. |
| `not_a_directory` | The root does not exist, or is not a directory, in the gateway's container. | Check the mount. A path that exists on the host and not in the container fails exactly like this. |
| `not_readable` | The directory is there and the gateway cannot read it. | Fix the permissions or the mount's read-only flag. |
| `root_not_permitted` | The root is not beneath any entry in `BODY_STORE_FILESYSTEM_BASES`. | Add the base, or move the store root under an existing one. |

## When a body cannot be read

Opening a result's response body reads it through the store, and an `in_place`
body is always returned as **content** rather than a redirect to a presigned
URL — so a store you own never has to be given CORS rules for the dashboard.
Bodies are capped at 32 MiB; over that the read is refused with
`body_too_large`.

Two answers say different things and want different responses:

| Answer | Meaning | What to do |
|---|---|---|
| **410 `body_gone`** | The object is not there, or the store refused that key. | Nothing. The body is genuinely gone — aged out under the store owner's retention, deleted by hand, or never written. The result itself is unaffected. |
| **503 `body_store_unavailable`** | The store could not be reached, its secret could not be decrypted, or the call failed for any other reason. | Fix the store, then reload. The body is probably still there. Run **Test** for the specific code, and check the store's last-failure field. |

The distinction is the point: `body_gone` is final and `body_store_unavailable`
is temporary. A store whose network broke reports the second, so nobody
concludes their bodies were deleted.

## Related

- [Body storage configuration](../install/configuration.md#body-stores) — the
  gateway, ingestor and worker variables.
- [Secrets & Encryption](secrets.md#body_store_aes_key) — the key that protects
  store credentials, and rotating it.
- [Retention & Aggregation](retention.md#body-storage) — what is deleted and
  what is not.
- [Probe Agents](../install/agents.md#body-storage) — the agent side of the
  arrangement.
- [Upgrading](upgrading.md#body-stores-0433) — what to set before the upgrade.
