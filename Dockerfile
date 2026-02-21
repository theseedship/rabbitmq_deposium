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
