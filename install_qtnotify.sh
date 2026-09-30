#!/bin/bash
#
# install_qtnotify.sh
#
# Builds and installs qtnotify, the Qt5 dialog that tempmon uses to warn
# about a hot board on a machine that actually has a screen attached.
#
# Installs (with the default prefix):
#   /usr/local/bin/qtnotify                     the dialog binary
#   /usr/local/bin/qtnotifier                   symlink to qtnotify
#   /usr/local/bin/tempmon_alert                symlink to qtnotify
#   /usr/local/bin/qtnotify-broadcast           runs it in every session
#   /usr/local/share/icons/hicolor/*/apps/      window icon
#   /usr/local/share/doc/qtnotify/README.md     documentation
#
# Run as root (or with sudo), from the directory containing this script.
#
# Usage:
#   sudo ./install_qtnotify.sh [options]
#
# Options:
#   --prefix DIR      install prefix (default /usr/local)
#   --no-deps         do not touch the package manager, fail if Qt5 is
#                     missing instead
#   --wire-tempmon    point /etc/tempmon/config.txt at the installed
#                     qtnotify-broadcast and set NOTIFICATION_TYPE=3,
#                     keeping a .bak copy. See the note it prints.
#   -h, --help        this help

set -euo pipefail

PROG="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="/usr/local"
NO_DEPS=0
WIRE_TEMPMON=0
TEMPMON_CONFIG="/etc/tempmon/config.txt"

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
            --no-deps) NO_DEPS=1; shift ;;
            --wire-tempmon) WIRE_TEMPMON=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) err "unknown argument: $1"; usage >&2; exit 2 ;;
        esac
    done

    [[ "$PREFIX" == /* ]] || die "--prefix must be an absolute path" 2
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "run as root (sudo ./$PROG)"
    fi
}

check_sources() {
    local path

    for path in Makefile src/Makefile src/tempmon_alert.cpp \
                assets/qtnotify.qrc scripts/qtnotify-broadcast.sh
    do
        [[ -f "$SCRIPT_DIR/$path" ]] || die "$path not found next to this script"
    done

    bash -n "$SCRIPT_DIR/scripts/qtnotify-broadcast.sh" \
        || die "scripts/qtnotify-broadcast.sh has a syntax error, refusing to install"
}

install_deps() {
    local missing=()

    command -v g++ >/dev/null 2>&1 || missing+=("a C++ compiler")
    command -v make >/dev/null 2>&1 || missing+=("make")
    command -v pkg-config >/dev/null 2>&1 || missing+=("pkg-config")
    pkg-config --exists Qt5Widgets 2>/dev/null || missing+=("Qt5 widgets headers")

    if [[ "${#missing[@]}" -eq 0 ]]; then
        log "build dependencies already present"
        return 0
    fi

    if [[ "$NO_DEPS" -eq 1 ]]; then
        die "missing: ${missing[*]} (and --no-deps was given)"
    fi

    log "installing build dependencies (${missing[*]})"

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y build-essential pkg-config qtbase5-dev
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y gcc-c++ make pkgconf-pkg-config qt5-qtbase-devel
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm base-devel pkgconf qt5-base
    else
        die "no supported package manager, install these by hand: ${missing[*]}"
    fi

    pkg-config --exists Qt5Widgets 2>/dev/null \
        || die "Qt5 widgets headers still missing after the install"
}

build() {
    log "building"
    make -C "$SCRIPT_DIR" clean >/dev/null 2>&1 || true
    make -C "$SCRIPT_DIR"
}

run_tests() {
    if [[ ! -x "$SCRIPT_DIR/tests/run_tests.sh" ]]; then
        return 0
    fi

    log "running the test suite"
    if ! "$SCRIPT_DIR/tests/run_tests.sh" --quiet; then
        die "tests failed, refusing to install (run tests/run_tests.sh for detail)"
    fi
}

install_files() {
    log "installing into $PREFIX"
    make -C "$SCRIPT_DIR" install PREFIX="$PREFIX"

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
    fi
}

verify() {
    local binary="$PREFIX/bin/qtnotify"

    [[ -x "$binary" ]] || die "$binary was not installed"

    log "installed: $("$binary" --version)"

    # The dialog itself needs a display, this only proves it runs and that
    # the message it would show is the right one.
    "$binary" --dry-run 82.4 75 "$(hostname)" >/dev/null \
        || die "$binary does not run correctly"
}

wire_tempmon() {
    local broadcast="$PREFIX/bin/qtnotify-broadcast"
    local stamp

    if [[ ! -f "$TEMPMON_CONFIG" ]]; then
        err "$TEMPMON_CONFIG not found, skipping --wire-tempmon"
        return 0
    fi

    stamp="$(date +%Y%m%d%H%M%S)"
    cp -a "$TEMPMON_CONFIG" "$TEMPMON_CONFIG.bak.$stamp"
    log "backed up $TEMPMON_CONFIG to $TEMPMON_CONFIG.bak.$stamp"

    if grep -q '^[[:space:]]*NOTIFICATION_QTNOTIFIER=' "$TEMPMON_CONFIG"; then
        sed -i "s|^[[:space:]]*NOTIFICATION_QTNOTIFIER=.*|NOTIFICATION_QTNOTIFIER=$broadcast|" \
            "$TEMPMON_CONFIG"
    else
        printf 'NOTIFICATION_QTNOTIFIER=%s\n' "$broadcast" >> "$TEMPMON_CONFIG"
    fi

    if grep -q '^[[:space:]]*NOTIFICATION_TYPE=' "$TEMPMON_CONFIG"; then
        sed -i 's|^[[:space:]]*NOTIFICATION_TYPE=.*|NOTIFICATION_TYPE=3|' "$TEMPMON_CONFIG"
    else
        printf 'NOTIFICATION_TYPE=3\n' >> "$TEMPMON_CONFIG"
    fi

    log "set NOTIFICATION_TYPE=3 and NOTIFICATION_QTNOTIFIER=$broadcast"
    echo
    echo "NOTE: tempmon.sh does not read those two keys yet, it always uses"
    echo "      wall. Until it does, call the notifier from your own hook:"
    echo "        $broadcast \"\$temp\" \"\$THRESHOLD_C\" \"\$(hostname)\""
}

main() {
    parse_args "$@"
    check_root
    check_sources
    install_deps
    build
    run_tests
    install_files
    verify

    if [[ "$WIRE_TEMPMON" -eq 1 ]]; then
        wire_tempmon
    fi

    echo
    log "done"
    echo "binary:     $PREFIX/bin/qtnotify  (also qtnotifier, tempmon_alert)"
    echo "broadcast:  $PREFIX/bin/qtnotify-broadcast"
    echo "try it:     qtnotify --timeout 20 82.4 75 \$(hostname)"
    echo "headless:   qtnotify --dry-run 82.4 75        (no display needed)"
    echo "all screens: sudo qtnotify-broadcast --dry-run 82.4 75"
    echo "remove:     sudo ./uninstall_qtnotify.sh"
}

main "$@"
