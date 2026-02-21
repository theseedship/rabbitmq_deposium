# RabbitMQ Deposium

RabbitMQ 4.1 with management plugin, configured for Deposium infrastructure.

## What's included

- RabbitMQ 4.1.4 Management Alpine
- `.erlang.cookie` permission fix for RabbitMQ 4.x (must be 0600)
- Wrapper entrypoint for runtime permission repair
- Ports: 5672 (AMQP), 15672 (Management UI)

## Railway Deployment

### Create the service

1. **Add** → **GitHub Repo** → `rabbitmq_deposium`
2. Railway will auto-build the Dockerfile

### Environment variables

```env
RABBITMQ_DEFAULT_USER=deposium
RABBITMQ_DEFAULT_PASS=<strong_password>
RABBITMQ_MANAGEMENT_ALLOW_WEB_ACCESS=true
RABBITMQ_MANAGEMENT_PATH_PREFIX=/
```

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

## Local Development

Used in `deposium-local/docker-compose.yml` as the `rabbitmq` service.

```bash
# Ports
5672  → AMQP
15672 → Management UI (http://rabbitmq.localhost)
```

## Version pinning

Pinned to `4.1.4-management-alpine`. Update the `FROM` line to upgrade.
Test locally before deploying to production.
