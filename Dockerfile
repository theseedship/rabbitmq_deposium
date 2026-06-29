FROM rabbitmq:4.1.4-management-alpine

# Default nodename uses localhost (works on Railway + any environment)
# Override via RABBITMQ_NODENAME env var for Docker Compose with custom hostnames
ENV RABBITMQ_NODENAME=rabbit@localhost
ENV RABBITMQ_USE_LONGNAME=false

# Create data directory and set strict permissions for RabbitMQ 4.x
# RabbitMQ 4.x requires .erlang.cookie to be 0600 (owner-only access)
RUN mkdir -p /var/lib/rabbitmq && \
    chown -R rabbitmq:rabbitmq /var/lib/rabbitmq && \
    chmod 700 /var/lib/rabbitmq

# Raise consumer_timeout above our longest ingestion run (n8n EXECUTIONS_TIMEOUT_MAX=7200s).
# Default is 1_800_000 ms (30 min) — SHORTER than a big multi-page doc (54 min observed),
# so the broker would close the channel and requeue a still-healthy execution (n8n acks the
# message only when the run finishes). Set it >2h so n8n's own EXECUTIONS_TIMEOUT always
# fires first. conf.d snippet is additive (does not clobber the RABBITMQ_DEFAULT_USER conf
# the entrypoint generates at runtime). 2026-06-29.
RUN mkdir -p /etc/rabbitmq/conf.d \
 && printf 'consumer_timeout = 7800000\n' > /etc/rabbitmq/conf.d/20-consumer-timeout.conf \
 && chown rabbitmq:rabbitmq /etc/rabbitmq/conf.d/20-consumer-timeout.conf

# Self-provision the full ingestion topology on every boot from a baked, auth-stripped
# definitions file. WHY: the Railway service was wiped on 2026-06-29 (redeploy without a
# volume) — empty broker → n8n could not declare run_0_0 (passive QueueDeclare 404) →
# ingestion halted prod+staging. With filesystem import a fresh/empty volume re-creates the
# exchanges, the 5 quorum run_* queues (with the exact app args), BOTH run_1_1 bindings
# (runs.cutting + the incident-critical runs.fusion that the app's assertQueues structurally
# cannot express), the n8n event bus and the DLQs — BEFORE n8n or the app connect.
# Import is additive + idempotent and NEVER deletes entities absent from the file.
# We deliberately do NOT set definitions.skip_if_unchanged: import must run on EVERY boot
# so that a restart also REPAIRS a topology that was damaged at runtime (a queue/binding
# deleted on a still-existing volume). skip_if_unchanged keys off the file hash, not broker
# state, so it would skip the re-import and leave the deleted queue missing — defeating the
# boot-time self-provisioning this image exists for. The re-declare of ~13 queues per boot
# is a cheap no-op when nothing changed.
# CAVEAT: with import enabled, a BLANK node skips default user/vhost creation, so the login
# user is (re)seeded idempotently in docker-entrypoint-wrapper.sh from $RABBITMQ_DEFAULT_*.
# Regenerate definitions.json from the live broker on any topology change (see README).
RUN printf 'definitions.import_backend = local_filesystem\ndefinitions.local.path = /etc/rabbitmq/definitions.json\n' \
      > /etc/rabbitmq/conf.d/15-definitions.conf \
 && chown rabbitmq:rabbitmq /etc/rabbitmq/conf.d/15-definitions.conf
COPY --chown=rabbitmq:rabbitmq definitions.json /etc/rabbitmq/definitions.json

# Entrypoint wrapper: fixes the erlang cookie perms (pre-boot) and seeds the login user
# (post-boot) to compensate for the import-suppresses-default-user behavior above.
COPY docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh
RUN chmod +x /docker-entrypoint-wrapper.sh

# Readiness gates on the login user EXISTING, not just the node running. On a blank/wiped
# volume the AMQP port opens before the background seed creates the env user, so a client
# connecting in that window gets ACCESS_REFUSED. Reporting healthy only once the user exists
# lets orchestrators (compose `depends_on: service_healthy`, Railway deploy gating) hold
# clients back until login works; client-side retries cover the rest. start-period is wide
# so the one-time blank-volume seed never counts as a failure.
HEALTHCHECK --interval=15s --timeout=10s --start-period=90s --retries=6 \
  CMD /sbin/su-exec rabbitmq env HOME=/var/lib/rabbitmq sh -c \
      'rabbitmq-diagnostics -q check_running && rabbitmqctl -q list_users | grep -qw "${RABBITMQ_DEFAULT_USER:-guest}"'

EXPOSE 5672 15672

ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
CMD ["rabbitmq-server"]
