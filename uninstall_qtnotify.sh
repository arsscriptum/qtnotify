#!/bin/bash
#
# uninstall_qtnotify.sh
#
# Removes everything install_qtnotify.sh put on the system: the binary,
# its two compatibility symlinks, the broadcast wrapper, the icons and
# the installed README.
#
# Nothing in /etc is touched. If you used --wire-tempmon, the keys it set
# in /etc/tempmon/config.txt are left alone (a backup of the original is
# next to it as config.txt.bak.<timestamp>), because tempmon keeps its
# own config and this script has no business editing it on the way out.
#
# Usage:
#   sudo ./uninstall_qtnotify.sh [options]
#
# Options:
#   --prefix DIR      prefix it was installed under (default /usr/local)
#   -n, --dry-run     list what would be removed, remove nothing
#   -h, --help        this help

set -euo pipefail

PROG="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="/usr/local"
DRY_RUN=0
ICON_SIZES=(16 32 64 128 256)
REMOVED=0

log() {
    echo "==> $1"
}

err() {
    echo "$PROG: $1" >&2
}

die() {
    err "$1"
    exit "${2:-1}"
}

usage() {
    sed -n '3,/^set -euo/p' "${BASH_SOURCE[0]}" \
        | sed -e '/^set -euo/d' -e 's/^#//' -e 's/^ //'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                [[ $# -ge 2 ]] || die "--prefix needs a directory" 2
                PREFIX="$2"
                shift 2
                ;;
            --prefix=*) PREFIX="${1#*=}"; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) err "unknown argument: $1"; usage >&2; exit 2 ;;
        esac
    done

    [[ "$PREFIX" == /* ]] || die "--prefix must be an absolute path" 2
}

remove_path() {
    local path="$1"

    [[ -e "$path" || -L "$path" ]] || return 0

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "would remove $path"
    else
        log "removing $path"
        rm -rf "$path"
    fi

    REMOVED=$((REMOVED + 1))
}

main() {
    local size

    parse_args "$@"

    if [[ "$DRY_RUN" -eq 0 && "$(id -u)" -ne 0 ]]; then
        die "run as root (sudo ./$PROG), or pass --dry-run to just look"
    fi

    remove_path "$PREFIX/bin/qtnotify"
    remove_path "$PREFIX/bin/qtnotifier"
    remove_path "$PREFIX/bin/tempmon_alert"
    remove_path "$PREFIX/bin/qtnotify-broadcast"

    for size in "${ICON_SIZES[@]}"; do
        remove_path "$PREFIX/share/icons/hicolor/${size}x${size}/apps/qtnotify.png"
    done

    remove_path "$PREFIX/share/icons/hicolor/scalable/apps/qtnotify.svg"
    remove_path "$PREFIX/share/doc/qtnotify"

    if [[ "$DRY_RUN" -eq 0 ]] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
    fi

    if [[ "$REMOVED" -eq 0 ]]; then
        log "nothing installed under $PREFIX, nothing to do"
        return 0
    fi

    log "done, $REMOVED path(s) $([[ "$DRY_RUN" -eq 1 ]] && echo "would be removed" || echo removed)"

    if [[ -d "$SCRIPT_DIR/bin" && "$DRY_RUN" -eq 0 ]]; then
        echo "the build tree is untouched, run 'make clean' to drop bin/ and obj/"
    fi
}

main "$@"
