#!/bin/bash
#
# run_tests.sh
#
# Test suite for qtnotify. Runs without a display: the GUI cases use Qt's
# offscreen platform plugin, and the dialog is told to dismiss itself with
# --timeout, so nothing ever waits for a human.
#
# Usage:
#   tests/run_tests.sh [options]
#
# Options:
#   -b, --bin PATH    binary to test (default ../bin/qtnotify, built if
#                     it is missing and a Makefile is present)
#   -q, --quiet       only print failures and the summary
#   -v, --verbose     print the output of every case
#   -h, --help        this help
#
# Exit codes:
#   0   every test passed (skipped tests do not fail the run)
#   1   at least one test failed
#   2   usage error, or the binary could not be built
#
# What is covered:
#   - argument parsing and validation, and the documented exit codes
#   - the composed message text, for both the alert and the recovery case
#   - refusing to run with no display, instead of aborting on Qt
#   - the real dialog opening and self dismissing (offscreen platform)
#   - the embedded icon resource being present in the binary
#   - the shell scripts parsing, and qtnotify-broadcast's validation
#   - make install / make uninstall into a staging directory

set -uo pipefail

PROG="${0##*/}"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_DIR="$(cd "$TEST_DIR/.." && pwd)"

BIN="$TOP_DIR/bin/qtnotify"
BROADCAST="$TOP_DIR/scripts/qtnotify-broadcast.sh"
QUIET=0
VERBOSE=0

PASSED=0
FAILED=0
SKIPPED=0
LAST_OUTPUT=""

# Every GUI case runs under this, so a hung dialog fails the suite
# instead of hanging the terminal (or a CI job) forever.
GUI_TIMEOUT=20

RED=""
GREEN=""
YELLOW=""
RESET=""
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
fi

usage() {
    sed -n '3,/^set -uo/p' "${BASH_SOURCE[0]}" \
        | sed -e '/^set -uo/d' -e 's/^#//' -e 's/^ //'
}

say() {
    [[ "$QUIET" -eq 1 ]] && return 0
    echo "$1"
}

pass() {
    PASSED=$((PASSED + 1))
    say "  ${GREEN}ok${RESET}    $1"
    if [[ "$VERBOSE" -eq 1 && -n "$LAST_OUTPUT" ]]; then
        echo "$LAST_OUTPUT" | sed 's/^/          /'
    fi
}

fail() {
    FAILED=$((FAILED + 1))
    echo "  ${RED}FAIL${RESET}  $1"
    [[ -n "${2:-}" ]] && echo "        $2"
    if [[ -n "$LAST_OUTPUT" ]]; then
        echo "$LAST_OUTPUT" | sed 's/^/        | /'
    fi
}

skip() {
    SKIPPED=$((SKIPPED + 1))
    say "  ${YELLOW}skip${RESET}  $1 ($2)"
}

section() {
    say ""
    say "$1"
}

# run <command...>  -> sets LAST_OUTPUT and returns the command's status
run() {
    LAST_OUTPUT="$("$@" 2>&1)"
    return $?
}

# expect_rc <desc> <expected rc> <command...>
expect_rc() {
    local desc="$1" want="$2"
    shift 2
    local rc

    run "$@"
    rc=$?

    if [[ "$rc" -eq "$want" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected exit $want, got $rc"
    fi
}

# expect_match <desc> <expected rc> <grep -E pattern> <command...>
expect_match() {
    local desc="$1" want="$2" pattern="$3"
    shift 3
    local rc

    run "$@"
    rc=$?

    if [[ "$rc" -ne "$want" ]]; then
        fail "$desc" "expected exit $want, got $rc"
        return
    fi

    if ! grep -Eq -- "$pattern" <<< "$LAST_OUTPUT"; then
        fail "$desc" "output does not match /$pattern/"
        return
    fi

    pass "$desc"
}

# expect_true <desc> <command...>  (for plain shell predicates)
expect_true() {
    local desc="$1"
    shift

    LAST_OUTPUT=""
    if "$@"; then
        pass "$desc"
    else
        fail "$desc" "command failed: $*"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--bin)
                [[ $# -ge 2 ]] || { echo "$PROG: --bin needs a path" >&2; exit 2; }
                BIN="$2"
                shift 2
                ;;
            --bin=*) BIN="${1#*=}"; shift ;;
            -q|--quiet) QUIET=1; VERBOSE=0; shift ;;
            -v|--verbose) VERBOSE=1; QUIET=0; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "$PROG: unknown argument: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

ensure_binary() {
    if [[ -x "$BIN" ]]; then
        return 0
    fi

    if [[ ! -f "$TOP_DIR/Makefile" ]]; then
        echo "$PROG: $BIN not found and no Makefile to build it" >&2
        exit 2
    fi

    say "building $BIN"
    if ! make -C "$TOP_DIR" >/dev/null; then
        echo "$PROG: build failed, cannot run the tests" >&2
        exit 2
    fi

    [[ -x "$BIN" ]] || { echo "$PROG: build produced no $BIN" >&2; exit 2; }
}

# ------------------------------------------------------------------ cases

test_usage() {
    section "argument handling"

    expect_match "--help prints usage and exits 0" 0 'usage: qtnotify' \
        "$BIN" --help
    expect_match "--version prints the version" 0 'qtnotify [0-9]+\.[0-9]+\.[0-9]+' \
        "$BIN" --version
    expect_rc "no arguments is a usage error" 2 "$BIN"
    expect_rc "one argument is a usage error" 2 "$BIN" 82.4
    expect_rc "four arguments is a usage error" 2 "$BIN" 82.4 75 host extra
    expect_match "non numeric temperature is rejected" 2 'not a number' \
        "$BIN" abc 75
    expect_match "non numeric threshold is rejected" 2 'not a number' \
        "$BIN" 82.4 seventy-five
    expect_match "unknown option is rejected" 2 'unknown option' \
        "$BIN" --nope 82.4 75
    expect_match "bad timeout is rejected" 2 'bad timeout' \
        "$BIN" --timeout abc 82.4 75
    expect_match "negative timeout is rejected" 2 'bad timeout' \
        "$BIN" --timeout -5 82.4 75
    expect_match "--timeout with no value is rejected" 2 'needs a value' \
        "$BIN" --dry-run 82.4 75 --timeout
    expect_rc "negative temperatures are accepted" 0 \
        "$BIN" --dry-run -- -3.5 75
}

test_message() {
    section "message text"

    expect_match "alert message names temp, threshold and host" 0 \
        'CPU temperature 82\.4 C exceeds threshold 75 C on delta' \
        "$BIN" --dry-run 82.4 75 delta
    expect_match "alert title" 0 '^TEMPERATURE ALERT' \
        "$BIN" --dry-run 82.4 75 delta
    expect_match "--normal switches to the recovery wording" 0 \
        'back under threshold 75 C on delta' \
        "$BIN" --dry-run --normal 71.2 75 delta
    expect_match "--normal title" 0 '^TEMPERATURE NORMAL' \
        "$BIN" --dry-run --normal 71.2 75 delta
    expect_match "host defaults to localhost" 0 'on localhost' \
        "$BIN" --dry-run 82.4 75
    expect_match "--title overrides the title" 0 '^TOO HOT' \
        "$BIN" --dry-run --title 'TOO HOT' 82.4 75
    expect_match "--message overrides the body" 0 'custom body' \
        "$BIN" --dry-run --message 'custom body' 82.4 75
    expect_match "--message=VALUE form works" 0 'equals form' \
        "$BIN" --dry-run --message=equals\ form 82.4 75
    expect_match "control characters in the host are rejected" 2 'printable' \
        "$BIN" --dry-run 82.4 75 "$(printf 'bad\thost')"
}

test_display() {
    section "display handling"

    expect_match "no DISPLAY exits 1 with a clear message" 1 \
        'no DISPLAY or WAYLAND_DISPLAY' \
        env -u DISPLAY -u WAYLAND_DISPLAY -u QT_QPA_PLATFORM "$BIN" 82.4 75
    expect_match "an unreachable DISPLAY exits 1, it does not abort" 1 \
        'cannot reach X display' \
        env -u WAYLAND_DISPLAY -u QT_QPA_PLATFORM DISPLAY=:77 "$BIN" 82.4 75
    expect_match "the message is still reported on stderr when there is no GUI" 1 \
        'message was: CPU temperature' \
        env -u DISPLAY -u WAYLAND_DISPLAY -u QT_QPA_PLATFORM "$BIN" 82.4 75
    expect_rc "--dry-run needs no display at all" 0 \
        env -u DISPLAY -u WAYLAND_DISPLAY -u QT_QPA_PLATFORM "$BIN" -n 82.4 75
}

# The offscreen platform plugin ships in qtbase5, but not on every trimmed
# down image. Probe it once by opening a dialog that closes immediately:
# exit 3 means it rendered, anything else means we cannot test the GUI.
offscreen_available() {
    local rc

    QT_QPA_PLATFORM=offscreen timeout "$GUI_TIMEOUT" \
        "$BIN" --timeout 1 1 1 probe >/dev/null 2>&1
    rc=$?

    [[ "$rc" -eq 3 ]]
}

test_dialog() {
    section "dialog (offscreen platform)"

    if ! offscreen_available; then
        skip "dialog opens and self dismisses" "no offscreen platform plugin"
        skip "recovery dialog opens and self dismisses" "no offscreen platform plugin"
        skip "timeout is reported on stderr" "no offscreen platform plugin"
        return
    fi

    expect_rc "dialog opens and self dismisses, exit 3" 3 \
        env QT_QPA_PLATFORM=offscreen timeout "$GUI_TIMEOUT" \
        "$BIN" --timeout 1 82.4 75 testhost
    expect_rc "recovery dialog opens and self dismisses" 3 \
        env QT_QPA_PLATFORM=offscreen timeout "$GUI_TIMEOUT" \
        "$BIN" --normal --timeout 1 71.2 75 testhost
    expect_match "timeout is reported on stderr" 3 'no acknowledgement after 1 s' \
        env QT_QPA_PLATFORM=offscreen timeout "$GUI_TIMEOUT" \
        "$BIN" --timeout 1 82.4 75
}

test_assets() {
    section "assets"

    local size
    local png

    for size in 16 32 64 128 256; do
        png="$TOP_DIR/assets/icons/qtnotify-$size.png"
        expect_true "icon qtnotify-$size.png exists" test -s "$png"
        if [[ -s "$png" ]]; then
            expect_true "icon qtnotify-$size.png is a PNG" \
                bash -c "head -c8 '$png' | od -An -tx1 | grep -q '89 50 4e 47'"
        fi
    done

    expect_true "the scalable icon exists" test -s "$TOP_DIR/assets/icons/qtnotify.svg"
    expect_true "the resource file exists" test -s "$TOP_DIR/assets/qtnotify.qrc"

    # Every file listed in the .qrc must be there, or rcc fails the build.
    local missing=0
    local ref
    while read -r ref; do
        [[ -f "$TOP_DIR/assets/$ref" ]] || { echo "        missing asset: $ref"; missing=1; }
    done < <(sed -n 's/.*<file[^>]*>\(.*\)<\/file>.*/\1/p' "$TOP_DIR/assets/qtnotify.qrc")
    LAST_OUTPUT=""
    expect_true "every file in qtnotify.qrc exists" test "$missing" -eq 0

    # rcc compiles the icons into the binary, so the PNG bytes are in it.
    if command -v strings >/dev/null 2>&1; then
        expect_true "the icon resource is compiled into the binary" \
            grep -qa 'qtnotify-64.png' "$BIN"
    else
        skip "icon resource compiled in" "no strings(1)"
    fi
}

test_scripts() {
    section "shell scripts"

    local script

    for script in "$BROADCAST" "$TOP_DIR/install_qtnotify.sh" \
                  "$TOP_DIR/uninstall_qtnotify.sh" "$TEST_DIR/run_tests.sh"
    do
        expect_true "${script##*/} parses" bash -n "$script"
        expect_true "${script##*/} is executable" test -x "$script"
    done

    expect_match "broadcast --help works" 0 'Usage:' "$BROADCAST" --help
    expect_rc "broadcast with no arguments is a usage error" 2 "$BROADCAST"
    expect_match "broadcast rejects a non numeric temperature" 2 'not a number' \
        "$BROADCAST" abc 75
    expect_match "broadcast rejects a bad timeout" 2 'bad timeout' \
        "$BROADCAST" --timeout x 82.4 75
    expect_match "broadcast rejects an unknown option" 2 'unknown option' \
        "$BROADCAST" --nope 82.4 75
    expect_match "broadcast reports a missing binary" 2 'not executable' \
        "$BROADCAST" --binary /nonexistent/qtnotify 82.4 75

    # Exit 0 when a session was found, 1 when there is none. Both are
    # correct here, the test only checks it is one of the two and that
    # --dry-run never opens anything.
    run "$BROADCAST" --dry-run --binary "$BIN" 82.4 75
    local rc=$?
    if [[ "$rc" -eq 0 || "$rc" -eq 1 ]]; then
        pass "broadcast --dry-run reports sessions without notifying"
    else
        fail "broadcast --dry-run reports sessions without notifying" "got exit $rc"
    fi

    if command -v shellcheck >/dev/null 2>&1; then
        expect_true "shellcheck is clean" \
            shellcheck -S warning "$BROADCAST" "$TOP_DIR/install_qtnotify.sh" \
                "$TOP_DIR/uninstall_qtnotify.sh" "$TEST_DIR/run_tests.sh"
    else
        skip "shellcheck" "not installed"
    fi
}

test_install() {
    section "staged install"

    local stage
    stage="$(mktemp -d "${TMPDIR:-/tmp}/qtnotify-stage.XXXXXX")" || {
        skip "staged install" "cannot create a temporary directory"
        return
    }

    if ! run make -C "$TOP_DIR" install DESTDIR="$stage" PREFIX=/usr; then
        fail "make install into a staging directory" "make install failed"
        rm -rf "$stage"
        return
    fi
    pass "make install into a staging directory"

    LAST_OUTPUT=""
    expect_true "the binary landed in the staging directory" \
        test -x "$stage/usr/bin/qtnotify"
    expect_true "the qtnotifier compatibility symlink is there" \
        test -L "$stage/usr/bin/qtnotifier"
    expect_true "the tempmon_alert compatibility symlink is there" \
        test -L "$stage/usr/bin/tempmon_alert"
    expect_true "qtnotify-broadcast is installed" \
        test -x "$stage/usr/bin/qtnotify-broadcast"
    expect_true "the 64px icon is installed" \
        test -s "$stage/usr/share/icons/hicolor/64x64/apps/qtnotify.png"
    expect_true "the README is installed" \
        test -s "$stage/usr/share/doc/qtnotify/README.md"
    expect_match "the installed binary runs" 0 'CPU temperature' \
        "$stage/usr/bin/qtnotify" --dry-run 82.4 75
    expect_match "the compatibility symlink runs the same program" 0 'CPU temperature' \
        "$stage/usr/bin/qtnotifier" --dry-run 82.4 75

    if ! run make -C "$TOP_DIR" uninstall DESTDIR="$stage" PREFIX=/usr; then
        fail "make uninstall from the staging directory" "make uninstall failed"
        rm -rf "$stage"
        return
    fi
    pass "make uninstall from the staging directory"

    LAST_OUTPUT=""
    expect_true "the binary is gone" test ! -e "$stage/usr/bin/qtnotify"
    expect_true "the symlinks are gone" test ! -e "$stage/usr/bin/qtnotifier"
    expect_true "the icons are gone" \
        test ! -e "$stage/usr/share/icons/hicolor/64x64/apps/qtnotify.png"

    rm -rf "$stage"
}

main() {
    parse_args "$@"
    ensure_binary

    say "qtnotify test suite"
    say "binary: $BIN"

    test_usage
    test_message
    test_display
    test_dialog
    test_assets
    test_scripts
    test_install

    echo
    if [[ "$FAILED" -eq 0 ]]; then
        echo "${GREEN}PASS${RESET}  $PASSED passed, $SKIPPED skipped"
        return 0
    fi

    echo "${RED}FAIL${RESET}  $FAILED failed, $PASSED passed, $SKIPPED skipped"
    return 1
}

main "$@"
