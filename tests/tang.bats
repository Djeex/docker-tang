#!/usr/bin/env bats
#
# Behavioral tests for the tang server as the container runs it:
# docker-entrypoint -> start-servers -> socat -> tangd /db, plus the
# check-servers healthcheck. Real binaries, no mocks; port 8080 as in prod.

bats_require_minimum_version 1.5.0

ENTRYPOINT=/usr/local/bin/docker-entrypoint
BASE=http://127.0.0.1:8080

setup() {
    cd /app || exit 1
    unset DOCKER_UID DOCKER_GID DOCKER_USER DOCKER_GROUP
    unset ENTRYPOINT_D ENTRYPOINT_RUN_AS_ROOT ENTRYPOINT_SKIP_CONFIG ENTRYPOINT_LOG_THRESHOLD
    export ENABLE_IPv4=1 ENABLE_IPv6=0
    rm -rf /db && mkdir -p /db
    LOG="$(mktemp)"
}

teardown() {
    stop_server
    rm -rf /db "$LOG" && mkdir -p /db
}

start_server() {
    ( exec "$ENTRYPOINT" start-servers >"$LOG" 2>&1 ) &
    disown 2>/dev/null || true
}

stop_server() {
    pkill -f start-servers 2>/dev/null || true
    pkill -x socat 2>/dev/null || true
    tries=0
    while pgrep -x socat >/dev/null && [ "$tries" -lt 20 ]; do
        tries=$((tries + 1))
        sleep 0.25
    done
}

wait_for_url() {
    tries=0
    while [ "$tries" -lt 40 ]; do
        curl -s -o /dev/null "$1" && return 0
        tries=$((tries + 1))
        sleep 0.25
    done
    return 1
}

has_ipv6() {
    ip -6 addr show dev lo 2>/dev/null | grep -q '::1'
}

# Thumbprints of the keys advertised by /adv, one per line, sorted.
adv_thumbprints() {
    curl -fsS "${1:-$BASE}/adv" | jq -r .payload | jose b64 dec -i- | jq -c '.keys[]' \
        | while read -r k; do echo "$k" | jose jwk thp -i-; echo; done | sort
}

# Thumbprints derived from the key file names in /db, sorted.
db_thumbprints() {
    find /db -name '*.jwk' -exec basename {} .jwk \; | sort
}

# Generate a tang key pair in /db the way tangd names them (<thp>.jwk).
seed_keys() {
    for alg in ES512 ECMR; do
        jose jwk gen -i "{\"alg\":\"$alg\"}" -o /tmp/seed.jwk
        mv /tmp/seed.jwk "/db/$(jose jwk thp -i /tmp/seed.jwk).jwk"
    done
    chmod 0440 /db/*.jwk
}

# ---- Key generation and persistence ---------------------------------------

@test "keys are created lazily on the first /adv request, not at startup" {
    start_server
    wait_for_url "$BASE/nope"
    [ -z "$(ls -A /db)" ]
    curl -fsS "$BASE/adv" >/dev/null
    [ "$(find /db -name '*.jwk' | wc -l)" -eq 2 ]
}

@test "/adv serves a signed JWS advertising one ES512 and one ECMR key" {
    start_server
    wait_for_url "$BASE/adv"
    run curl -fsS -D "$LOG.headers" "$BASE/adv"
    [ "$status" -eq 0 ]
    grep -qi '^content-type: application/jose+json' "$LOG.headers"
    echo "$output" > /tmp/adv.json
    algs="$(jq -r .payload /tmp/adv.json | jose b64 dec -i- | jq -r '[.keys[].alg] | sort | join(",")')"
    [ "$algs" = "ECMR,ES512" ]
    jq -r .payload /tmp/adv.json | jose b64 dec -i- > /tmp/keys.json
    jose jwk use -i /tmp/keys.json -r -u verify -o /tmp/verify.json
    jose jws ver -i /tmp/adv.json -k /tmp/verify.json
    rm -f "$LOG.headers"
}

@test "generated keys are 0440 <thumbprint>.jwk files owned by 12345:23456" {
    start_server
    wait_for_url "$BASE/adv"
    [ "$(adv_thumbprints)" = "$(db_thumbprints)" ]
    for f in /db/*.jwk; do
        [ "$(stat -c '%a %u:%g' "$f")" = "440 12345:23456" ]
    done
}

@test "existing keys are served unchanged and never regenerated" {
    seed_keys
    before="$(db_thumbprints)"
    start_server
    wait_for_url "$BASE/adv"
    [ "$(adv_thumbprints)" = "$before" ]
    [ "$(db_thumbprints)" = "$before" ]
    [ "$(stat -c '%u:%g' /db/*.jwk | sort -u)" = "12345:23456" ]
}

@test "keys survive a restart of the server" {
    start_server
    wait_for_url "$BASE/adv"
    first="$(adv_thumbprints)"
    stop_server
    start_server
    wait_for_url "$BASE/adv"
    [ "$(adv_thumbprints)" = "$first" ]
    [ "$(find /db -name '*.jwk' | wc -l)" -eq 2 ]
}

# ---- HTTP surface ----------------------------------------------------------

@test "GET /rec and unknown paths answer 404 like tangd upstream" {
    start_server
    wait_for_url "$BASE/adv"
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/rec")" = "404" ]
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/nope")" = "404" ]
}

@test "tangd runs as the unprivileged user behind socat" {
    start_server
    wait_for_url "$BASE/adv"
    [ "$(ps -o user= -p "$(pgrep -x socat | head -n1)")" = "user" ]
}

# ---- IPv4 / IPv6 listeners -------------------------------------------------

@test "listens on IPv4 only by default" {
    has_ipv6 || skip "no IPv6 loopback in this container"
    start_server
    wait_for_url "$BASE/adv"
    run curl -s -o /dev/null --max-time 2 "http://[::1]:8080/adv"
    [ "$status" -ne 0 ]
}

@test "ENABLE_IPv6=1 ENABLE_IPv4=0 listens on IPv6 only" {
    has_ipv6 || skip "no IPv6 loopback in this container"
    export ENABLE_IPv4=0 ENABLE_IPv6=1
    start_server
    wait_for_url "http://[::1]:8080/adv"
    run curl -s -o /dev/null --max-time 2 "$BASE/adv"
    [ "$status" -ne 0 ]
}

@test "start-servers exits when no listener is enabled" {
    export ENABLE_IPv4=0 ENABLE_IPv6=0
    run --separate-stderr "$ENTRYPOINT" start-servers
    [ "$status" -eq 0 ]
    ! pgrep -x socat
}

# ---- Healthcheck -----------------------------------------------------------

@test "check-servers succeeds while tang answers" {
    start_server
    wait_for_url "$BASE/adv"
    run check-servers
    [ "$status" -eq 0 ]
}

@test "check-servers fails when tang is down" {
    run check-servers
    [ "$status" -ne 0 ]
}

@test "check-servers probes IPv6 when ENABLE_IPv6=1" {
    has_ipv6 || skip "no IPv6 loopback in this container"
    start_server
    wait_for_url "$BASE/adv"
    ENABLE_IPv6=1 run check-servers
    [ "$status" -ne 0 ]
}
