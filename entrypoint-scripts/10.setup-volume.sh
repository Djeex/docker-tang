#!/bin/sh -e
# Hand /db (and existing keys) to the unprivileged user, as padhihomelab/tang does.

if [ -z "${ENTRYPOINT_RUN_AS_ROOT:-}" ]; then
    chown -R "$DOCKER_USER:$DOCKER_GROUP" /db
fi
