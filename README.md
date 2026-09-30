# qtnotify

A small Qt5 dialog that tells whoever is sitting in front of the machine
that the board is running hot.

It is the graphical half of
[tempmonitor.pi5](../tempmonitor.pi5): `tempmon.sh` broadcasts a `wall`
message to every tty, which is the right mechanism on a headless server
but is invisible to somebody looking at a desktop. `qtnotify` pops a red
modal box on the actual screen instead, and `qtnotify-broadcast` finds
the logged-in graphical sessions and opens one in each of them.

```
$ qtnotify --dry-run 82.4 75 delta
TEMPERATURE ALERT: CPU temperature 82.4 C exceeds threshold 75 C on delta
```

![the dialog icon](assets/icons/qtnotify-128.png)

## Build

Needs a C++17 compiler, `make`, `pkg-config` and the Qt5 widget headers.
There is no QObject subclass in the source, so no `moc` pass: the only
generated file is the icon resource, produced by `rcc`.

```sh
sudo apt-get install -y build-essential pkg-config qtbase5-dev   # or: sudo make deps
make                    # -> bin/qtnotify
make test               # 70 or so cases, no display needed
make run                # opens the real dialog on your display
```

| target | what it does |
| --- | --- |
| `make` | build `bin/qtnotify` |
| `make test` | build, then run `tests/run_tests.sh` |
| `make lint` | `bash -n` on every script, plus `shellcheck` if installed |
| `make run` | open a demo dialog that closes itself after 20 s |
| `sudo make deps` | install the build dependencies (apt, dnf or pacman) |
| `make install` | staged install into `$(DESTDIR)$(PREFIX)`, default `/usr/local` |
| `make uninstall` | remove exactly what `install` put there |
| `make assets` | re-render the PNG icons from `assets/icons/make_icons.py` |
| `make dist` | source tarball in `dist/` |
| `make clean` | drop `bin/` and `obj/` |

Useful knobs: `PREFIX=/usr`, `DESTDIR=/tmp/stage`, `DEBUG=1` (`-O0 -g3`),
`V=1` (echo the compiler command lines).

## Install

```sh
sudo ./install_qtnotify.sh              # deps, build, tests, install, verify
sudo ./install_qtnotify.sh --prefix /usr
sudo ./uninstall_qtnotify.sh            # --dry-run to see the list first
```

The installer checks the dependencies, builds, runs the test suite,
installs through `make install` and then proves the installed binary
runs. It touches nothing outside the prefix unless you pass
`--wire-tempmon`, which edits `/etc/tempmon/config.txt` (keeping a
timestamped backup).

What lands on the system, with the default prefix:

```
/usr/local/bin/qtnotify                          the dialog
/usr/local/bin/qtnotifier                        symlink -> qtnotify
/usr/local/bin/tempmon_alert                     symlink -> qtnotify
/usr/local/bin/qtnotify-broadcast                the session wrapper
/usr/local/share/icons/hicolor/*/apps/qtnotify.* window icon
/usr/local/share/doc/qtnotify/README.md          this file
```

The two symlinks exist for compatibility: `tempmonitor.pi5` ships
`NOTIFICATION_QTNOTIFIER=/bin/qtnotifier` in its config, and the source
file here has always been called `tempmon_alert.cpp`.

## Using it

```
qtnotify [options] <temp_c> <threshold_c> [hostname]
```

| option | meaning |
| --- | --- |
| `-t, --timeout SEC` | close the dialog by itself after `SEC` seconds, exit 3. `0` (the default) waits for the user |
| `-N, --normal` | recovery notice, green, "back under threshold" wording |
| `--title TEXT` | override the window title |
| `--message TEXT` | override the message body |
| `-n, --dry-run` | print the message to stdout, open no window |
| `-h, --help`, `-V, --version` | the usual |

Exit codes, which is what a calling script cares about:

| code | meaning |
| --- | --- |
| 0 | the user clicked GOT IT (or `--dry-run`, `--help`, `--version`) |
| 1 | no usable display, nothing was shown. The message is echoed to stderr so it is not lost |
| 2 | bad arguments |
| 3 | `--timeout` expired with nobody acknowledging |

A missing or unreachable `DISPLAY` is checked before Qt starts, so you
get exit 1 and one line on stderr rather than a Qt abort and a core dump
in the service log.

### Every screen on the box

A root service has no display of its own. `qtnotify-broadcast` walks the
active sessions (`loginctl`, falling back to `who`), works out each
one's display and X authority file, and runs `qtnotify` as that user:

```sh
sudo qtnotify-broadcast --dry-run 82.4 75            # list the targets
sudo qtnotify-broadcast 82.4 75 "$(hostname)"        # notify them all
sudo qtnotify-broadcast --normal --timeout 30 71.2 75
```

It defaults to `--timeout 120` and detaches the dialogs, so the caller is
not held open for as long as somebody takes to click. `--wait` reverses
that and reports the worst exit code. It exits 1 when there is no
graphical session at all, which is the signal to fall back to `wall`.

### Wiring it into tempmon

`tempmon.sh` currently always uses `wall`; its config file already
reserves the keys for this:

```
NOTIFICATION_TYPE=3                                   # 1 wall, 2 gui, 3 both
NOTIFICATION_QTNOTIFIER=/usr/local/bin/qtnotify-broadcast
```

Until `tempmon.sh` reads them, call the wrapper next to the existing
`broadcast` call:

```bash
broadcast() {
    local message="$1"
    wall "$message"
    [[ -x "$NOTIFICATION_QTNOTIFIER" ]] \
        && "$NOTIFICATION_QTNOTIFIER" --quiet "$temp" "$THRESHOLD_C" "$(hostname)"
}
```

Because the wrapper exits 1 when nothing graphical is running, it is
safe to call unconditionally on a headless board.

## Layout

```
Makefile                     build, test, install, package
install_qtnotify.sh          system installer (root)
uninstall_qtnotify.sh        the reverse, --dry-run supported
src/Makefile                 compile and link rules, rcc, dependency files
src/tempmon_alert.cpp        the whole program
assets/qtnotify.qrc          resource list, compiled into the binary
assets/icons/*.png           window icon, committed, rendered by
assets/icons/make_icons.py   a dependency free PNG renderer (zlib only)
assets/icons/qtnotify.svg    the same artwork as a vector
scripts/qtnotify-broadcast.sh  run the dialog in every active session
tests/run_tests.sh           the test suite
bin/, obj/                   build output, not in git
```

## Tests

`tests/run_tests.sh` needs no display: the GUI cases use Qt's `offscreen`
platform plugin and `--timeout`, so nothing waits for a human, and every
GUI case is wrapped in `timeout(1)`. It covers argument validation and
the documented exit codes, the composed message text, the no-display
path, the dialog actually opening and dismissing itself, the icons and
the resource being compiled in, the shell scripts, and a full
`make install` / `make uninstall` round trip into a staging directory.

```sh
tests/run_tests.sh            # -q quiet, -v verbose, -b PATH other binary
```

## Notes

- Qt5 on purpose: `qtbase5-dev` is what Raspberry Pi OS and Ubuntu ship
  by default on the boards this runs on. The source avoids the classes
  Qt6 dropped (no `QRegExp`, no deprecated `QString` overloads), so a
  Qt6 port should come down to changing `QT_PKGS` in `src/Makefile`.
- The dialog is deliberately ugly: flat red, one button, no icon in the
  message area. It is meant to be impossible to ignore, not pretty.
- Wayland sessions work through the Qt wayland plugin when it is
  installed (`qtwayland5`); otherwise Qt falls back to XWayland, which
  is why `qtnotify-broadcast` still sets `XAUTHORITY`.
