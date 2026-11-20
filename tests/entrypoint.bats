#!/usr/bin/env bats
#
# Behavioral tests for docker-entrypoint.sh, run as root inside the `test`
# image stage against the real busybox addgroup/adduser and su-exec.
#
# /etc/passwd and /etc/group persist across tests of one bats run, so tests
# that create identities use names/ids unique to the test number.

bats_require_minimum_version 1.5.0

ENTRYPOINT=/usr/local/bin/docker-entrypoint

setup() {
    cd /app || exit 1
    unset DOCKER_UID DOCKER_GID DOCKER_USER DOCKER_GROUP
    unset ENTRYPOINT_D ENTRYPOINT_RUN_AS_ROOT ENTRYPOINT_SKIP_CONFIG ENTRYPOINT_LOG_THRESHOLD
    rm -rf /db && mkdir -p /db
    SCRIPTS_DIR="$(mktemp -d)"
    N="$BATS_TEST_NUMBER"
}

teardown() {
    rm -rf "$SCRIPTS_DIR" /db && mkdir -p /db
}

# Use an isolated identity unique to this test.
use_test_identity() {
    export DOCKER_USER="u$N" DOCKER_GROUP="g$N"
    export DOCKER_UID=$((30000 + N)) DOCKER_GID=$((40000 + N))
}

# ---- Defaults (padhihomelab/alpine-base contract) --------------------------

@test "runs the command as user:user with UID 12345 / GID 23456 by default" {
    run --separate-stderr "$ENTRYPOINT" sh -c 'id -u; id -g; id -un; id -gn; echo "$HOME"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "12345" ]
    [ "${lines[1]}" = "23456" ]
    [ "${lines[2]}" = "user" ]
    [ "${lines[3]}" = "user" ]
    [ "${lines[4]}" = "/home/user" ]
}

@test "exports the resolved DOCKER_* variables to the command" {
    run --separate-stderr "$ENTRYPOINT" sh -c 'echo "$DOCKER_UID:$DOCKER_GID:$DOCKER_USER:$DOCKER_GROUP"'
    [ "$status" -eq 0 ]
    [ "$output" = "12345:23456:user:user" ]
}

@test "reuses the user and group on a container restart" {
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 0 ]
    run --separate-stderr "$ENTRYPOINT" id -u
    [ "$status" -eq 0 ]
    [ "$output" = "12345" ]
    [[ "$stderr" == *"Reusing existing group 'user' (GID 23456)"* ]]
    [[ "$stderr" == *"Reusing existing user 'user' (UID 12345)"* ]]
}

@test "honours DOCKER_UID, DOCKER_GID, DOCKER_USER and DOCKER_GROUP" {
    use_test_identity
    run --separate-stderr "$ENTRYPOINT" sh -c 'id -u; id -g; id -un; id -gn'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$DOCKER_UID" ]
    [ "${lines[1]}" = "$DOCKER_GID" ]
    [ "${lines[2]}" = "$DOCKER_USER" ]
    [ "${lines[3]}" = "$DOCKER_GROUP" ]
}

# ---- Validation ------------------------------------------------------------

@test "fails when DOCKER_UID is not numeric" {
    export DOCKER_UID=abc
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"DOCKER_UID 'abc' is not a valid numeric user id."* ]]
}

@test "fails when DOCKER_GID is not numeric" {
    export DOCKER_GID=-1
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"DOCKER_GID '-1' is not a valid numeric group id."* ]]
}

@test "fails when the group name already exists with another GID" {
    use_test_identity
    addgroup -S -g $((50000 + N)) "$DOCKER_GROUP"
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Group '$DOCKER_GROUP' already exists with GID $((50000 + N)), expected $DOCKER_GID."* ]]
}

@test "fails when the user name already exists with another UID" {
    use_test_identity
    adduser -D -u $((50000 + N)) "$DOCKER_USER"
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"User '$DOCKER_USER' already exists with UID $((50000 + N)), expected $DOCKER_UID."* ]]
}

@test "reuses the group that already owns DOCKER_GID" {
    use_test_identity
    export DOCKER_GID=100
    run --separate-stderr "$ENTRYPOINT" sh -c 'id -g; id -gn'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "100" ]
    [ "${lines[1]}" = "users" ]
    [[ "$stderr" == *"GID 100 already belongs to group 'users', reusing it."* ]]
}

@test "reuses the user that already owns DOCKER_UID" {
    use_test_identity
    export DOCKER_UID=65534
    run --separate-stderr "$ENTRYPOINT" sh -c 'id -u; id -un; id -g'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "65534" ]
    [ "${lines[1]}" = "nobody" ]
    [ "${lines[2]}" = "$DOCKER_GID" ]
    [[ "$stderr" == *"UID 65534 already belongs to user 'nobody', reusing it."* ]]
}

@test "fails when no command is given" {
    run --separate-stderr "$ENTRYPOINT"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"No command to run."* ]]
}

# ---- /db ownership (10.setup-volume.sh) ------------------------------------

@test "chowns /db recursively to the unprivileged user" {
    mkdir -p /db/sub
    touch /db/key.jwk /db/sub/file
    chmod 0400 /db/key.jwk
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 0 ]
    [ "$(stat -c '%u:%g' /db)" = "12345:23456" ]
    [ "$(stat -c '%u:%g' /db/key.jwk)" = "12345:23456" ]
    [ "$(stat -c '%u:%g' /db/sub/file)" = "12345:23456" ]
    [ "$(stat -c '%a' /db/key.jwk)" = "400" ]
}

@test "chowns /db to overridden DOCKER_UID/DOCKER_GID" {
    use_test_identity
    touch /db/key.jwk
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 0 ]
    [ "$(stat -c '%u:%g' /db/key.jwk)" = "$DOCKER_UID:$DOCKER_GID" ]
}

@test "ENTRYPOINT_RUN_AS_ROOT keeps root and leaves /db ownership alone" {
    export ENTRYPOINT_RUN_AS_ROOT=1
    touch /db/key.jwk
    run --separate-stderr "$ENTRYPOINT" id -u
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    [ "$(stat -c '%u:%g' /db/key.jwk)" = "0:0" ]
    [[ "$stderr" == *"starting up as 'root'"* ]]
}

# ---- ENTRYPOINT_D configuration scripts ------------------------------------

@test "runs executable .sh scripts from ENTRYPOINT_D in sorted order as root" {
    export ENTRYPOINT_D="$SCRIPTS_DIR"
    printf '#!/bin/sh\necho "20 $(id -u) $DOCKER_USER" >> %s/trace\n' "$SCRIPTS_DIR" > "$SCRIPTS_DIR/20.b.sh"
    printf '#!/bin/sh\necho "10 $(id -u) $DOCKER_USER" >> %s/trace\n' "$SCRIPTS_DIR" > "$SCRIPTS_DIR/10.a.sh"
    chmod +x "$SCRIPTS_DIR"/*.sh
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 0 ]
    [ "$(cat "$SCRIPTS_DIR/trace")" = "$(printf '10 0 user\n20 0 user')" ]
}

@test "ignores non-executable and non-.sh files in ENTRYPOINT_D" {
    export ENTRYPOINT_D="$SCRIPTS_DIR"
    printf '#!/bin/sh\ntouch %s/ran-noexec\n' "$SCRIPTS_DIR" > "$SCRIPTS_DIR/10.noexec.sh"
    printf '#!/bin/sh\ntouch %s/ran-txt\n' "$SCRIPTS_DIR" > "$SCRIPTS_DIR/20.script.txt"
    chmod +x "$SCRIPTS_DIR/20.script.txt"
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 0 ]
    [ ! -e "$SCRIPTS_DIR/ran-noexec" ]
    [ ! -e "$SCRIPTS_DIR/ran-txt" ]
    [[ "$stderr" == *"Ignoring $SCRIPTS_DIR/10.noexec.sh: not executable."* ]]
    [[ "$stderr" == *"Ignoring $SCRIPTS_DIR/20.script.txt: not a '.sh' script."* ]]
}

@test "a failing configuration script is reported but does not block startup" {
    export ENTRYPOINT_D="$SCRIPTS_DIR"
    printf '#!/bin/sh\nexit 3\n' > "$SCRIPTS_DIR/10.fail.sh"
    chmod +x "$SCRIPTS_DIR/10.fail.sh"
    run --separate-stderr "$ENTRYPOINT" echo started
    [ "$status" -eq 0 ]
    [ "$output" = "started" ]
    [[ "$stderr" == *"10.fail.sh exited with status 3, continuing."* ]]
}

@test "ENTRYPOINT_SKIP_CONFIG skips the configuration scripts" {
    export ENTRYPOINT_SKIP_CONFIG=1
    touch /db/key.jwk
    run --separate-stderr "$ENTRYPOINT" id -u
    [ "$status" -eq 0 ]
    [ "$output" = "12345" ]
    [ "$(stat -c '%u' /db/key.jwk)" = "0" ]
}

@test "logs and continues when ENTRYPOINT_D is empty" {
    export ENTRYPOINT_D="$SCRIPTS_DIR"
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"No files found in $SCRIPTS_DIR, skipping configuration."* ]]
}

# ---- Logging ---------------------------------------------------------------

@test "prints the version banner from the VERSION file" {
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Tang - Version $(cat /app/VERSION)"* ]]
}

@test "ENTRYPOINT_LOG_THRESHOLD=1 includes debug messages" {
    run --separate-stderr "$ENTRYPOINT" true
    [[ "$stderr" == *"Launching /etc/docker-entrypoint.d/99-extra-scripts/10.setup-volume.sh"* ]]
}

@test "ENTRYPOINT_LOG_THRESHOLD=3 hides debug and info messages" {
    export ENTRYPOINT_LOG_THRESHOLD=3
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"Launching"* ]]
    [[ "$stderr" != *"Starting up as"* ]]
}

@test "ENTRYPOINT_LOG_THRESHOLD=5 silences the entrypoint entirely" {
    export ENTRYPOINT_LOG_THRESHOLD=5
    run --separate-stderr "$ENTRYPOINT" echo ok
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
    [ -z "$stderr" ]
}

@test "a non-numeric ENTRYPOINT_LOG_THRESHOLD falls back to 1 with a warning" {
    export ENTRYPOINT_LOG_THRESHOLD=loud
    run --separate-stderr "$ENTRYPOINT" true
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"ENTRYPOINT_LOG_THRESHOLD 'loud' is not numeric, using 1."* ]]
}
