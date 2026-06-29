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

# Create wrapper script to fix .erlang.cookie permissions at runtime
RUN echo '#!/bin/sh' > /docker-entrypoint-wrapper.sh && \
    echo 'set -e' >> /docker-entrypoint-wrapper.sh && \
    echo 'if [ -f /var/lib/rabbitmq/.erlang.cookie ]; then' >> /docker-entrypoint-wrapper.sh && \
    echo '  chmod 600 /var/lib/rabbitmq/.erlang.cookie' >> /docker-entrypoint-wrapper.sh && \
    echo '  chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie' >> /docker-entrypoint-wrapper.sh && \
    echo 'fi' >> /docker-entrypoint-wrapper.sh && \
    echo 'exec docker-entrypoint.sh "$@"' >> /docker-entrypoint-wrapper.sh && \
    chmod +x /docker-entrypoint-wrapper.sh

EXPOSE 5672 15672

ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]
CMD ["rabbitmq-server"]
