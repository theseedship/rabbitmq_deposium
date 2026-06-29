#!/bin/sh
# Entrypoint wrapper for the Deposium RabbitMQ image.
#
# Three responsibilities beyond the stock rabbitmq entrypoint:
#
#  1. Guarantee a STABLE .erlang.cookie BEFORE the node starts. On a blank volume
#     the server beam AND our post-boot rabbitmqctl seed (below) would otherwise
#     race to *create* the cookie; that race intermittently leaves it momentarily
#     root-owned and crashes prelaunch with ".erlang.cookie: eacces". Pre-creating
#     it (this is a single node — no cluster — so a fresh random value is fine)
#     removes the race. On a warm volume the persisted cookie is kept; we only
#     re-assert perms (RabbitMQ 4.x requires 0600).
#
#  2. Seed the runtime login user AFTER the node is up. REQUIRED because
#     conf.d/15-definitions.conf enables filesystem definitions import, and on a
#     BLANK node RabbitMQ deliberately SKIPS creating the default user/vhost when
#     a definitions file is present (official behavior — "Schema Definition Export
#     and Import" docs). Without this seed a wiped volume would import the full
#     topology but have NO login user, locking out n8n and the app (ACCESS_REFUSED)
#     — strictly worse than an empty broker. The seed is idempotent (safe on a warm
#     volume too) and reads the password from the environment only
#     ($RABBITMQ_DEFAULT_PASS); no secret is baked into the image.
#
#  3. Hand control to the stock entrypoint via exec.
set -e

COOKIE=/var/lib/rabbitmq/.erlang.cookie

# (1) Stable cookie — pre-boot.
if [ ! -f "$COOKIE" ]; then
  COOKIE_VAL=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
  printf '%s' "$COOKIE_VAL" > "$COOKIE"
fi
chmod 600 "$COOKIE"
chown rabbitmq:rabbitmq "$COOKIE"

# (2) Idempotent login-user seed — post-boot, backgrounded.
if [ -n "$RABBITMQ_DEFAULT_USER" ] && [ -n "$RABBITMQ_DEFAULT_PASS" ]; then
  (
    # Run rabbitmqctl as the rabbitmq user with the right HOME so it resolves the
    # cookie at /var/lib/rabbitmq/.erlang.cookie without an ownership warning.
    RBTCTL="/sbin/su-exec rabbitmq env HOME=/var/lib/rabbitmq rabbitmqctl"

    # Retry await_startup until the node is reachable: this block is backgrounded
    # right before exec'ing the entrypoint, so on the first attempts the beam/epmd
    # is not up yet and a single await_startup would fail fast (nodedown) rather
    # than wait. Once it returns 0 the node is fully booted AND definitions import
    # has completed, so the "/" vhost exists before we set permissions on it.
    i=0
    until $RBTCTL await_startup >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge 60 ]; then
        echo "[entrypoint-wrapper] WARNING: node not reachable after 120s; login user not seeded" >&2
        exit 0
      fi
      sleep 2
    done

    $RBTCTL add_user "$RABBITMQ_DEFAULT_USER" "$RABBITMQ_DEFAULT_PASS" 2>/dev/null \
      || $RBTCTL change_password "$RABBITMQ_DEFAULT_USER" "$RABBITMQ_DEFAULT_PASS"
    $RBTCTL set_user_tags "$RABBITMQ_DEFAULT_USER" administrator
    $RBTCTL set_permissions -p / "$RABBITMQ_DEFAULT_USER" ".*" ".*" ".*"
    echo "[entrypoint-wrapper] ensured login user '$RABBITMQ_DEFAULT_USER' (definitions-import blank-node guard)"
  ) &
fi

# (3) Stock entrypoint.
exec docker-entrypoint.sh "$@"
