#!/bin/sh
# Drop-in replacement for the padhihomelab/alpine-base entrypoint used by
# padhihomelab/tang: same variables, same defaults, same ENTRYPOINT_D
# contract. Runs as root, creates the unprivileged user, runs the
# configuration scripts, then drops privileges with su-exec.

export ENTRYPOINT_D="${ENTRYPOINT_D:-/etc/docker-entrypoint.d}"
export ENTRYPOINT_LOG_THRESHOLD="${ENTRYPOINT_LOG_THRESHOLD:-1}"
export ENTRYPOINT_RUN_AS_ROOT="${ENTRYPOINT_RUN_AS_ROOT:-}"
export ENTRYPOINT_SKIP_CONFIG="${ENTRYPOINT_SKIP_CONFIG:-}"

CYAN="\033[1;36m"
NC="\033[0m"

# Log levels: 1 = debug, 2 = info, 3 = warning, 4 = error, 5+ = silent.
case "$ENTRYPOINT_LOG_THRESHOLD" in
    ''|*[!0-9]*) INVALID_THRESHOLD=$ENTRYPOINT_LOG_THRESHOLD; ENTRYPOINT_LOG_THRESHOLD=1 ;;
esac

log() {
    [ "$1" -ge "$ENTRYPOINT_LOG_THRESHOLD" ] || return 0
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}
fail() { log 4 "[✗] $*"; exit 1; }

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
}

print_banner() {
    version=$(cat VERSION 2>/dev/null || echo "unknown")
    title="Tang - Version ${version}"
    lines="Source: https://git.djeex.fr/Djeex/docker-tang
Mirror: https://github.com/Djeex/docker-tang"

    width=${#title}
    old_ifs=$IFS
    IFS='
'
    for l in $lines; do
        [ ${#l} -gt "$width" ] && width=${#l}
    done
    IFS=$old_ifs
    width=$((width + 2))

    border=""
    i=0
    while [ "$i" -lt "$width" ]; do
        border="${border}─"
        i=$((i + 1))
    done
    printf "${CYAN}╭%s╮${NC}\n" "$border"

    total_pad=$((width - ${#title}))
    left=$((total_pad / 2))
    right=$((total_pad - left))
    printf "${CYAN}│${NC}%*s%s%*s${CYAN}│${NC}\n" "$left" "" "$title" "$right" ""

    printf "${CYAN}├%s┤${NC}\n" "$border"

    IFS='
'
    for l in $lines; do
        printf "${CYAN}│${NC} %-*s${CYAN}│${NC}\n" "$((width - 1))" "$l"
    done
    IFS=$old_ifs

    printf "${CYAN}╰%s╯${NC}\n" "$border"
}

[ "$ENTRYPOINT_LOG_THRESHOLD" -ge 5 ] || print_banner >&2

if [ -n "${INVALID_THRESHOLD:-}" ]; then
    log 3 "[!] ENTRYPOINT_LOG_THRESHOLD '$INVALID_THRESHOLD' is not numeric, using 1."
fi

[ "$#" -gt 0 ] || fail "No command to run."

setup_group() {
    log 2 "[~] Checking group '$DOCKER_GROUP' (GID $DOCKER_GID)..."
    gid_of_name=$(getent group "$DOCKER_GROUP" | cut -d: -f3)
    name_of_gid=$(getent group "$DOCKER_GID" | cut -d: -f1)

    if [ -n "$gid_of_name" ]; then
        [ "$gid_of_name" -eq "$DOCKER_GID" ] \
            || fail "Group '$DOCKER_GROUP' already exists with GID $gid_of_name, expected $DOCKER_GID."
        log 1 "[i] Reusing existing group '$DOCKER_GROUP' (GID $DOCKER_GID)."
    elif [ -n "$name_of_gid" ]; then
        log 3 "[!] GID $DOCKER_GID already belongs to group '$name_of_gid', reusing it."
        DOCKER_GROUP=$name_of_gid
    else
        addgroup -S -g "$DOCKER_GID" "$DOCKER_GROUP" \
            || fail "Failed to create group '$DOCKER_GROUP' with GID $DOCKER_GID."
        log 1 "[✓] Created group '$DOCKER_GROUP' (GID $DOCKER_GID)."
    fi
}

setup_user() {
    log 2 "[~] Checking user '$DOCKER_USER' (UID $DOCKER_UID)..."
    uid_of_name=$(getent passwd "$DOCKER_USER" | cut -d: -f3)
    name_of_uid=$(getent passwd "$DOCKER_UID" | cut -d: -f1)

    if [ -n "$uid_of_name" ]; then
        [ "$uid_of_name" -eq "$DOCKER_UID" ] \
            || fail "User '$DOCKER_USER' already exists with UID $uid_of_name, expected $DOCKER_UID."
        log 1 "[i] Reusing existing user '$DOCKER_USER' (UID $DOCKER_UID)."
    elif [ -n "$name_of_uid" ]; then
        log 3 "[!] UID $DOCKER_UID already belongs to user '$name_of_uid', reusing it."
        DOCKER_USER=$name_of_uid
    else
        adduser -D -g "" -G "$DOCKER_GROUP" -h "/home/$DOCKER_USER" -u "$DOCKER_UID" "$DOCKER_USER" \
            || fail "Failed to create user '$DOCKER_USER' with UID $DOCKER_UID."
        log 1 "[✓] Created user '$DOCKER_USER' (UID $DOCKER_UID)."
    fi
}

run_config_scripts() {
    scripts=$(find "$ENTRYPOINT_D" -follow -type f 2>/dev/null | sort -n)
    if [ -z "$scripts" ]; then
        log 2 "[i] No files found in $ENTRYPOINT_D, skipping configuration."
        return 0
    fi

    log 2 "[~] Running configuration scripts from $ENTRYPOINT_D..."
    while IFS= read -r f; do
        case "$f" in
            *.sh)
                if [ -x "$f" ]; then
                    log 1 "[→] Launching $f"
                    "$f" </dev/null
                    rc=$?
                    # Like padhihomelab/alpine-base, a failing script does
                    # not prevent startup; it is reported instead.
                    [ "$rc" -eq 0 ] || log 3 "[!] $f exited with status $rc, continuing."
                else
                    log 3 "[!] Ignoring $f: not executable."
                fi
                ;;
            *)
                log 3 "[!] Ignoring $f: not a '.sh' script."
                ;;
        esac
    done <<EOF
$scripts
EOF
    log 2 "[✓] Configuration complete."
}

if [ -z "$ENTRYPOINT_RUN_AS_ROOT" ]; then
    export DOCKER_GID="${DOCKER_GID:-23456}"
    export DOCKER_UID="${DOCKER_UID:-12345}"
    export DOCKER_GROUP="${DOCKER_GROUP:-user}"
    export DOCKER_USER="${DOCKER_USER:-user}"

    is_uint "$DOCKER_GID" || fail "DOCKER_GID '$DOCKER_GID' is not a valid numeric group id."
    is_uint "$DOCKER_UID" || fail "DOCKER_UID '$DOCKER_UID' is not a valid numeric user id."

    setup_group
    setup_user
    export DOCKER_GROUP DOCKER_USER
fi

if [ -z "$ENTRYPOINT_SKIP_CONFIG" ]; then
    run_config_scripts
else
    log 2 "[i] ENTRYPOINT_SKIP_CONFIG is set, skipping configuration."
fi

if [ -n "$ENTRYPOINT_RUN_AS_ROOT" ]; then
    log 3 "[!] ENTRYPOINT_RUN_AS_ROOT is set, starting up as 'root'."
    exec "$@"
fi

HOME=$(getent passwd "$DOCKER_USER" | cut -d: -f6)
export HOME="${HOME:-/home/$DOCKER_USER}"
log 2 "[→] Starting up as '$DOCKER_USER' ($DOCKER_UID:$DOCKER_GID)."
exec su-exec "$DOCKER_USER:$DOCKER_GROUP" "$@"
