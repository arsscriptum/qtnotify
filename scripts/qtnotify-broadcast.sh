#!/bin/bash
#
# qtnotify-broadcast.sh
#
# Runs qtnotify inside every active graphical session on this machine.
#
# A root service such as tempmon.service has no DISPLAY of its own, so it
# cannot pop a dialog directly: it has to find the logged-in graphical
# sessions, become each owner, and point the binary at that session's
# display and X authority file. That is all this script does. It is the
# GUI counterpart of wall, which is what tempmon.sh uses for the tty
# broadcast.
#
# Usage:
#   qtnotify-broadcast [options] <temp_c> <threshold_c> [hostname]
#
# Options:
#   -t, --timeout SEC   dialog self dismisses after SEC seconds (default
#                       120, 0 waits forever, which leaks a process per
#                       alert if nobody is sitting in front of the screen)
#   -N, --normal        recovery notice (green) instead of an alert
#       --title TEXT    override the window title
#       --message TEXT  override the message body
#   -u, --user USER     only notify this user's sessions
#   -b, --binary PATH   qtnotify binary to run (default: first on PATH,
#                       then the bin/ directory next to this script)
#   -w, --wait          wait for the dialogs to be dismissed, and report
#                       the worst exit code (default: fire and forget)
#   -n, --dry-run       list the sessions that would be notified
#   -q, --quiet         no progress output, errors still go to stderr
#   -h, --help          this help
#
# Exit codes:
#   0   at least one session notified (or listed, with --dry-run)
#   1   no active graphical session found, nothing was displayed
#   2   usage error
#   3   with --wait: a dialog timed out without being acknowledged
#
# Examples:
#   qtnotify-broadcast 82.4 75 "$(hostname)"
#   qtnotify-broadcast --dry-run 82.4 75
#   qtnotify-broadcast --normal --timeout 30 71.2 75 delta
#
# Run as root to reach every user's session. As a normal user only your
# own sessions are considered, which is what you want when testing.

set -uo pipefail

PROG="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TIMEOUT_SEC=120
NORMAL=0
TITLE=""
MESSAGE=""
ONLY_USER=""
BINARY=""
WAIT=0
DRY_RUN=0
QUIET=0
TEMP_C=""
THRESHOLD_C=""
HOST_NAME=""

# Highest exit code seen from a dialog, reported with --wait.
WORST_RC=0
NOTIFIED=0

log() {
    [[ "$QUIET" -eq 1 ]] && return 0
    echo "$PROG: $1"
}

err() {
    echo "$PROG: $1" >&2
}

die() {
    err "$1"
    exit "${2:-2}"
}

# The header comment above is the manual: print it, minus the leading
# hashes, up to the first line of code.
usage() {
    sed -n '3,/^set -uo/p' "${BASH_SOURCE[0]}" \
        | sed -e '/^set -uo/d' -e 's/^#//' -e 's/^ //'
}

is_number() {
    [[ "$1" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]
}

need_value() {
    # $1 option name, $2 remaining argument count
    [[ "$2" -ge 2 ]] || die "$1 needs a value"
}

parse_args() {
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--timeout)
                need_value "$1" "$#"
                TIMEOUT_SEC="$2"
                shift 2
                ;;
            --timeout=*) TIMEOUT_SEC="${1#*=}"; shift ;;
            -N|--normal) NORMAL=1; shift ;;
            --title)
                need_value "$1" "$#"
                TITLE="$2"
                shift 2
                ;;
            --title=*) TITLE="${1#*=}"; shift ;;
            --message)
                need_value "$1" "$#"
                MESSAGE="$2"
                shift 2
                ;;
            --message=*) MESSAGE="${1#*=}"; shift ;;
            -u|--user)
                need_value "$1" "$#"
                ONLY_USER="$2"
                shift 2
                ;;
            --user=*) ONLY_USER="${1#*=}"; shift ;;
            -b|--binary)
                need_value "$1" "$#"
                BINARY="$2"
                shift 2
                ;;
            --binary=*) BINARY="${1#*=}"; shift ;;
            -w|--wait) WAIT=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -q|--quiet) QUIET=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; positional+=("$@"); break ;;
            -*) err "unknown option: $1"; usage >&2; exit 2 ;;
            *) positional+=("$1"); shift ;;
        esac
    done

    if [[ "${#positional[@]}" -lt 2 ]]; then
        err "need <temp_c> and <threshold_c>"
        usage >&2
        exit 2
    fi

    if [[ "${#positional[@]}" -gt 3 ]]; then
        die "too many arguments (got ${#positional[@]}, expected at most 3)"
    fi

    TEMP_C="${positional[0]}"
    THRESHOLD_C="${positional[1]}"
    HOST_NAME="${positional[2]:-$(hostname)}"

    is_number "$TEMP_C" || die "temp_c '$TEMP_C' is not a number"
    is_number "$THRESHOLD_C" || die "threshold_c '$THRESHOLD_C' is not a number"
    [[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]] || die "bad timeout '$TIMEOUT_SEC', expected whole seconds"
    [[ -n "$ONLY_USER" && ! "$ONLY_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] && die "bad user name '$ONLY_USER'"

    return 0
}

resolve_binary() {
    local candidate

    if [[ -n "$BINARY" ]]; then
        [[ -x "$BINARY" ]] || die "qtnotify binary '$BINARY' is not executable" 2
        return 0
    fi

    for candidate in \
        "$(command -v qtnotify 2>/dev/null)" \
        "$SCRIPT_DIR/../bin/qtnotify" \
        "$SCRIPT_DIR/bin/qtnotify" \
        /usr/local/bin/qtnotify \
        /usr/bin/qtnotify
    do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            BINARY="$candidate"
            return 0
        fi
    done

    die "qtnotify binary not found, build it with make or pass --binary PATH" 2
}

# Best effort X authority file for a user whose session we are entering.
# Display managers put it in different places, and a root caller needs an
# explicit XAUTHORITY because it does not inherit the user's environment.
find_xauthority() {
    local user="$1"
    local uid="$2"
    local display="$3"
    local home
    local candidate

    home="$(getent passwd "$user" | cut -d: -f6)"

    for candidate in \
        "/run/user/$uid/gdm/Xauthority" \
        "/run/user/$uid/xauth_"* \
        "/run/user/$uid/.mutter-Xwaylandauth."* \
        "${home:+$home/.Xauthority}" \
        "/var/run/lightdm/$user/xauthority" \
        "/var/lib/lightdm/.Xauthority" \
        "/var/run/sddm/"*
    do
        if [[ -n "$candidate" && -f "$candidate" && -r "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # Nothing found: an X session started by startx usually still works
    # through the socket when the caller is the same user.
    [[ -n "$display" ]] && return 1
    return 1
}

find_wayland_display() {
    local uid="$1"
    local socket

    for socket in "/run/user/$uid/wayland-"[0-9]*; do
        [[ -S "$socket" ]] || continue
        [[ "$socket" == *.lock ]] && continue
        echo "${socket##*/}"
        return 0
    done

    return 1
}

# Emits one "user<TAB>uid<TAB>type<TAB>display" line per active session.
list_sessions() {
    local session
    local key value
    local s_user="" s_uid="" s_type="" s_display="" s_active="" s_state=""

    if command -v loginctl >/dev/null 2>&1; then
        while read -r session; do
            [[ -n "$session" ]] || continue
            s_user=""; s_uid=""; s_type=""; s_display=""; s_active=""; s_state=""

            while IFS='=' read -r key value; do
                case "$key" in
                    Name)    s_user="$value" ;;
                    User)    s_uid="$value" ;;
                    Type)    s_type="$value" ;;
                    Display) s_display="$value" ;;
                    Active)  s_active="$value" ;;
                    State)   s_state="$value" ;;
                esac
            done < <(loginctl show-session "$session" 2>/dev/null)

            [[ "$s_type" == "x11" || "$s_type" == "wayland" ]] || continue
            [[ "$s_active" == "yes" || "$s_state" == "active" || "$s_state" == "online" ]] || continue
            [[ -n "$s_user" && -n "$s_uid" ]] || continue

            if [[ "$s_type" == "wayland" && -z "$s_display" ]]; then
                s_display="$(find_wayland_display "$s_uid")" || s_display=""
            fi

            [[ -n "$s_display" ]] || continue

            printf '%s\t%s\t%s\t%s\n' "$s_user" "$s_uid" "$s_type" "$s_display"
        done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
        return 0
    fi

    # No systemd: fall back to who, which reports "gp tty7 ... (:0)".
    who 2>/dev/null | while read -r s_user _ _ _ s_display; do
        [[ "$s_display" =~ ^\((:[0-9.]+)\)$ ]] || continue
        s_uid="$(id -u "$s_user" 2>/dev/null)" || continue
        printf '%s\t%s\tx11\t%s\n' "$s_user" "$s_uid" "${BASH_REMATCH[1]}"
    done
}

# Command prefix that switches to another user, empty when we already are
# that user (the common case when testing by hand).
as_user_cmd() {
    local user="$1"

    if [[ "$user" == "$(id -un)" ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        return 1
    fi

    if command -v runuser >/dev/null 2>&1; then
        echo "runuser -u $user --"
    elif command -v sudo >/dev/null 2>&1; then
        echo "sudo -n -u $user --"
    else
        return 1
    fi
}

notify_session() {
    local user="$1" uid="$2" type="$3" display="$4"
    local prefix
    local xauth
    local -a env_args=()
    local -a cmd=()
    local rc=0

    if ! prefix="$(as_user_cmd "$user")"; then
        log "skipping $user ($type $display): cannot switch to that user, run as root"
        return 1
    fi

    env_args=("XDG_RUNTIME_DIR=/run/user/$uid")

    if [[ "$type" == "wayland" ]]; then
        env_args+=("WAYLAND_DISPLAY=$display")
    else
        env_args+=("DISPLAY=$display")
        if xauth="$(find_xauthority "$user" "$uid" "$display")"; then
            env_args+=("XAUTHORITY=$xauth")
        fi
    fi

    cmd=("$BINARY" "--timeout" "$TIMEOUT_SEC")
    [[ "$NORMAL" -eq 1 ]] && cmd+=("--normal")
    [[ -n "$TITLE" ]] && cmd+=("--title" "$TITLE")
    [[ -n "$MESSAGE" ]] && cmd+=("--message" "$MESSAGE")
    cmd+=("--" "$TEMP_C" "$THRESHOLD_C" "$HOST_NAME")

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s\t%s\t%s\t%s\n' "$user" "$uid" "$type" "$display"
        log "would run: ${prefix:+$prefix }env ${env_args[*]} ${cmd[*]}"
        return 0
    fi

    log "notifying $user on $type $display"

    if [[ "$WAIT" -eq 1 ]]; then
        # shellcheck disable=SC2086
        $prefix env "${env_args[@]}" "${cmd[@]}"
        rc=$?
        [[ "$rc" -gt "$WORST_RC" ]] && WORST_RC="$rc"
        [[ "$rc" -eq 0 || "$rc" -eq 3 ]] || err "$user: qtnotify exited $rc"
        return 0
    fi

    # Fire and forget: setsid detaches the dialog so a service calling us
    # is not held open for as long as the user takes to click GOT IT.
    # shellcheck disable=SC2086
    setsid $prefix env "${env_args[@]}" "${cmd[@]}" >/dev/null 2>&1 &
    disown 2>/dev/null || true

    return 0
}

main() {
    local line user uid type display

    parse_args "$@"
    resolve_binary

    while IFS=$'\t' read -r user uid type display; do
        [[ -n "$user" ]] || continue
        [[ -n "$ONLY_USER" && "$user" != "$ONLY_USER" ]] && continue

        if notify_session "$user" "$uid" "$type" "$display"; then
            NOTIFIED=$((NOTIFIED + 1))
        fi
    done < <(list_sessions)

    if [[ "$NOTIFIED" -eq 0 ]]; then
        err "no active graphical session found, nothing displayed"
        return 1
    fi

    log "$NOTIFIED session(s) notified"

    [[ "$WAIT" -eq 1 && "$WORST_RC" -eq 3 ]] && return 3
    return 0
}

main "$@"
