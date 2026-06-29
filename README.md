# RabbitMQ Deposium

RabbitMQ 4.1 with management plugin, configured for Deposium infrastructure.

## What's included

- RabbitMQ 4.1.4 Management Alpine
- `consumer_timeout = 7800000` (>2h) so the broker never requeues a still-running
  long ingestion execution (n8n acks only when the run finishes)
- **Self-provisioning topology on boot** — the full ingestion topology is baked into
  the image (`definitions.json`) and imported on every start, so a fresh/empty volume
  rebuilds itself before n8n or the app connect (see below)
- Stable `.erlang.cookie` handling + login-user seed via `docker-entrypoint-wrapper.sh`
- Ports: 5672 (AMQP), 15672 (Management UI)

## Self-provisioning topology (the wipe guard)

On 2026-06-29 the Railway service was redeployed **without a volume**, which wiped the
entire RabbitMQ topology on prod **and** staging: every queue/exchange/binding was gone,
so n8n could no longer activate its workflows (`QueueDeclare … 404 NOT-FOUND no queue
'run_0_0'`) and ingestion halted.

To make a wipe survivable, the image now **imports a baked definitions file on every boot**:

- `conf.d/15-definitions.conf` enables `definitions.import_backend = local_filesystem`
  pointing at `/etc/rabbitmq/definitions.json`.
- `definitions.json` (committed, **auth-stripped**) contains the exchanges, the 5 quorum
  `run_*` queues with their exact arguments, **both** `run_1_1` bindings
  (`runs.cutting` **and** the incident-critical `runs.fusion`), the `deposium.events.n8n`
  classic bus and the DLQs.
- The import is **additive + idempotent** and **never deletes** entities that exist in the
  broker but not in the file (`definitions.skip_if_unchanged = true` also avoids re-import
  churn when nothing changed). Runtime-created users/queues survive restarts.

### Why the entrypoint seeds the login user

When `definitions.import_backend` is configured, a **blank node deliberately skips creating
the default user and virtual host** (official RabbitMQ behavior). So an auth-stripped
definitions file alone would rebuild the topology on a wiped volume but leave the broker with
**no login user** → `ACCESS_REFUSED` for n8n and the app. `docker-entrypoint-wrapper.sh`
therefore (re)seeds the login user **idempotently** from `$RABBITMQ_DEFAULT_USER` /
`$RABBITMQ_DEFAULT_PASS` after the node is up. No password is ever baked into the image — the
value is read from the environment only. The wrapper also pre-creates a stable `.erlang.cookie`
so the node and the seed don't race to create it on a blank volume.

> A persistent volume on `/var/lib/rabbitmq` is **still required** — self-provisioning makes a
> wipe *survivable*, not impossible. Keep the volume; it preserves messages and runtime state.

### Regenerating `definitions.json` after a topology change

`definitions.json` must be regenerated from a **live broker** whenever the topology changes
(new queue, new binding, changed args) — never hand-edited, so it always captures entities no
application code asserts (the n8n bus, `indexation_queue`, the per-queue DLQs) and the second
`run_1_1` binding:

```bash
# export from a broker that has the intended, complete topology (e.g. local dev)
docker exec deposium-rabbitmq rabbitmqctl export_definitions /tmp/live.json
docker cp deposium-rabbitmq:/tmp/live.json ./live.json

# strip auth + node-specific metadata; KEEP vhosts (a blank node won't create "/" itself
# once import is enabled), exchanges, queues, bindings, policies, parameters
jq 'del(.users, .permissions, .topic_permissions, .global_parameters)' live.json > definitions.json
rm live.json
```

Then commit, and mirror the same file to the local stack at
`deposium-local/dockerfiles/rabbitmq-definitions.json` (the local image builds separately).

> **Queue args are immutable.** A quorum queue's type/arguments cannot be changed by re-import
> or re-assert. To change them you must regenerate `definitions.json` **and** delete+recreate
> the affected queue — neither import nor the app's `assertQueues` can mutate an existing one.

## Railway Deployment

### Create the service

1. **Add** → **GitHub Repo** → `rabbitmq_deposium`
2. Railway will auto-build the Dockerfile
3. **Attach a volume mounted at `/var/lib/rabbitmq`** (required — see above)

### Environment variables

```env
RABBITMQ_DEFAULT_USER=deposium
RABBITMQ_DEFAULT_PASS=<strong_password>
RABBITMQ_MANAGEMENT_ALLOW_WEB_ACCESS=true
RABBITMQ_MANAGEMENT_PATH_PREFIX=/
```

> Do **not** run `railway variables --set` immediately after a `git push` — it cancels the
> in-flight build, so the new image never goes live.

### Networking

- **Port**: 5672 (AMQP — used by n8n workflows)
- **Management UI**: 15672 (optional — generate a public domain if you want web access)
- Internal hostname: `rabbitmq.railway.internal`

### How n8n connects

n8n workflows use `amqplib` to connect to RabbitMQ. In n8n credentials:

```
Host: rabbitmq.railway.internal
Port: 5672
User: deposium
Password: <same as RABBITMQ_DEFAULT_PASS>
Vhost: /
```

> Do **not** tick "Assert queue" in the n8n RabbitMQ trigger for the `run_*` queues — n8n
> would create them as classic queues, which conflicts (`PRECONDITION_FAILED`) with the quorum
> queues this image provisions. The queues are guaranteed to exist by the boot-time import.

## Local Development

Used in `deposium-local/docker-compose.yml` as the `rabbitmq` service, which builds its own
copy from `deposium-local/dockerfiles/Dockerfile.rabbitmq` (identical except the nodename).
Keep `dockerfiles/rabbitmq-definitions.json` in sync with this repo's `definitions.json`.

```bash
# Ports
5672  → AMQP
15672 → Management UI (http://rabbitmq.localhost)
```

## Version pinning

Pinned to `4.1.4-management-alpine`. Update the `FROM` line to upgrade.
Test locally before deploying to production.
