#!/usr/bin/env bash
#
# Drop-in compatibility test against padhihomelab/tang.
#
#   1. padhihomelab/tang generates keys in a fresh volume and a secret is
#      bound to it with `clevis encrypt tang`;
#   2. the new image is started on the very same volume;
#   3. it must advertise the same thumbprints, keep the key files untouched
#      (names, mode, owner), log no error, report healthy, and let clevis
#      decrypt the secret.
#
# Then a fresh volume checks first-start behaviour of the new image alone.
#
# Only uses named volumes and a user network (no bind mount, no published
# port), so it runs the same against a remote dind daemon as locally.
#
# Usage: tests/compat.sh [NEW_IMAGE] [REFERENCE_IMAGE] [CLIENT_IMAGE] [CLEVIS_IMAGE]

set -euo pipefail
export MSYS_NO_PATHCONV=1

NEW=${1:-tang:ci}
REF=${2:-tang:padhi-reference}
CLIENT=${3:-tang:test}
CLEVIS=${4:-tang:clevis}

ID="tang-compat-$$"
NET="$ID-net"
VOL="$ID-db"
FRESH_VOL="$ID-fresh"
SECRET="compat-secret-$$-$RANDOM"
FAILED=0

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
ok()   { log "[✓] $*"; }
ko()   { log "[✗] $*"; FAILED=1; }

cleanup() {
    docker rm -f "$ID-ref" "$ID-new" "$ID-fresh" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm "$VOL" "$FRESH_VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Run a shell snippet in the client image on the test network, with the
# volume mounted read-only at /db. volume-nocopy matters: while the volume is
# still empty, a plain mount would copy the client image's root-owned /db
# into it, undoing the server's chown and making tangd fail to write keys.
client() {
    local vol=$1; shift
    docker run --rm --network "$NET" \
        --mount "type=volume,src=$vol,dst=/db,readonly,volume-nocopy" \
        "$CLIENT" sh -c "$*"
}

# Sorted thumbprints of the keys advertised by http://tang:8080/adv.
adv_thumbprints() {
    client "$1" 'curl -fsS --retry 20 --retry-delay 1 --retry-all-errors http://tang:8080/adv \
        | jq -r .payload | jose b64 dec -i- | jq -c ".keys[]" \
        | while read -r k; do echo "$k" | jose jwk thp -i-; echo; done | sort'
}

# name, mode, uid, gid of every file in the volume.
db_listing() {
    client "$1" 'cd /db && find . -type f -exec stat -c "%n %a %u %g" {} + | sort'
}

wait_healthy() {
    local status=""
    for _ in $(seq 1 30); do
        status=$(docker inspect -f '{{.State.Health.Status}}' "$1")
        [ "$status" = "healthy" ] && return 0
        sleep 1
    done
    log "[!] $1 health status: $status"
    return 1
}

start_tang() {
    local name=$1 image=$2 vol=$3
    docker run -d --name "$name" --network "$NET" --network-alias tang \
        --health-interval 2s -v "$vol:/db" "$image" >/dev/null
}

docker network create "$NET" >/dev/null
docker volume create "$VOL" >/dev/null
docker volume create "$FRESH_VOL" >/dev/null

# ---- 1. Reference: padhihomelab/tang -----------------------------------------

log "[~] Starting reference image $REF"
start_tang "$ID-ref" "$REF" "$VOL"
REF_THP=$(adv_thumbprints "$VOL")
REF_LS=$(db_listing "$VOL")
log "[i] Reference thumbprints:"; echo "$REF_THP"
log "[i] Reference key files:"; echo "$REF_LS"
[ "$(echo "$REF_LS" | grep -c '\.jwk ')" -eq 2 ] || ko "reference did not create 2 keys"

log "[~] Binding a secret with clevis against the reference"
JWE=$(printf '%s' "$SECRET" | docker run --rm -i --network "$NET" "$CLEVIS" \
    clevis encrypt tang '{"url":"http://tang:8080"}' -y || true)
[ -n "$JWE" ] && ok "clevis encrypt succeeded" || ko "clevis encrypt failed"

docker rm -f "$ID-ref" >/dev/null

# ---- 2. New image on the same volume -----------------------------------------

log "[~] Starting new image $NEW on the reference volume"
start_tang "$ID-new" "$NEW" "$VOL"
if wait_healthy "$ID-new"; then ok "new image is healthy"; else ko "new image is not healthy"; fi

NEW_THP=$(adv_thumbprints "$VOL")
NEW_LS=$(db_listing "$VOL")
if [ "$NEW_THP" = "$REF_THP" ]; then ok "same thumbprints advertised"; else
    ko "thumbprints differ"; echo "$NEW_THP"; fi
if [ "$NEW_LS" = "$REF_LS" ]; then ok "key files unchanged (names, mode, owner)"; else
    ko "key files changed"; echo "$NEW_LS"; fi

LOGS=$(docker logs "$ID-new" 2>&1)
if echo "$LOGS" | grep -qiE 'denied|error|fail|✗|exited with status'; then
    ko "errors in new image logs"; echo "$LOGS"
else
    ok "no error in new image logs"
fi

DECRYPTED=$(printf '%s' "$JWE" | docker run --rm -i --network "$NET" "$CLEVIS" clevis decrypt || true)
if [ "$DECRYPTED" = "$SECRET" ]; then ok "clevis decrypt with the new image succeeded"; else
    ko "clevis decrypt with the new image failed"; fi

docker restart "$ID-new" >/dev/null
wait_healthy "$ID-new" || ko "new image is not healthy after restart"
[ "$(adv_thumbprints "$VOL")" = "$REF_THP" ] && [ "$(db_listing "$VOL")" = "$REF_LS" ] \
    && ok "keys unchanged after restart" || ko "keys changed after restart"

docker rm -f "$ID-new" >/dev/null

# ---- 3. New image on an empty volume -----------------------------------------

log "[~] Starting new image $NEW on an empty volume"
start_tang "$ID-fresh" "$NEW" "$FRESH_VOL"
if wait_healthy "$ID-fresh"; then ok "fresh instance is healthy"; else ko "fresh instance is not healthy"; fi

FRESH_THP=$(adv_thumbprints "$FRESH_VOL")
FRESH_LS=$(db_listing "$FRESH_VOL")
EXPECTED_LS=$(echo "$FRESH_THP" | sed 's#^\(.*\)$#./\1.jwk 440 12345 23456#' | sort)
if [ "$(echo "$FRESH_THP" | wc -l)" -eq 2 ] && [ "$FRESH_LS" = "$EXPECTED_LS" ]; then
    ok "fresh instance generated 2 keys as <thp>.jwk, 0440, 12345:23456"
else
    ko "unexpected fresh key files"; echo "$FRESH_LS"
fi

if [ "$FAILED" -ne 0 ]; then
    log "[✗] Compatibility test FAILED"
    exit 1
fi
log "[✓] Compatibility test passed"
