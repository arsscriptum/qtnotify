# qtnotify -- top level Makefile
#
#   make                 build bin/qtnotify
#   make test            build, then run the test suite
#   make run             build, then pop a demo dialog on your display
#   make deps            install the build dependencies (needs root)
#   make install         staged install into $(DESTDIR)$(PREFIX)
#   make uninstall       remove what install put there
#   make clean           remove bin/ and obj/
#   make assets          re-render the PNG icons from make_icons.py
#   make dist            tarball of the source tree in dist/
#   make help            this list
#
# Knobs (all overridable on the command line or from the environment):
#
#   PREFIX=/usr          install prefix, default /usr/local
#   DESTDIR=/tmp/stage   staging root for packaging, default empty
#   DEBUG=1              build -O0 -g3 instead of -O2
#   V=1                  echo the compiler command lines
#
# install_qtnotify.sh is the friendlier front end for a real machine: it
# checks the dependencies, builds, runs make install and tells you how to
# wire it into tempmon. This Makefile stays packaging friendly and never
# touches anything outside $(DESTDIR)$(PREFIX).

PACKAGE  := qtnotify
VERSION  := 1.0.0

PREFIX   ?= /usr/local
DESTDIR  ?=
BINDIR   ?= $(PREFIX)/bin
DATADIR  ?= $(PREFIX)/share
ICONDIR  ?= $(DATADIR)/icons/hicolor
DOCDIR   ?= $(DATADIR)/doc/$(PACKAGE)

BIN_NAME := qtnotify
BINARY   := bin/$(BIN_NAME)
BROADCAST := scripts/qtnotify-broadcast.sh

# Compatibility names. tempmonitor.pi5's config.txt ships
# NOTIFICATION_QTNOTIFIER=/bin/qtnotifier, and the source file is called
# tempmon_alert.cpp, so both names resolve to the same binary.
ALIASES  := qtnotifier tempmon_alert

ICON_SIZES := 16 32 64 128 256

# make_icons.py wants them comma separated.
comma          := ,
empty          :=
space          := $(empty) $(empty)
ICON_SIZES_CSV := $(subst $(space),$(comma),$(ICON_SIZES))
INSTALL    := install
SHELLS     := $(BROADCAST) install_qtnotify.sh uninstall_qtnotify.sh tests/run_tests.sh

ifeq ($(V),1)
Q :=
else
Q := @
endif

.PHONY: all build test check run demo deps clean distclean install uninstall \
        assets dist lint help

all: build

build:
	$(Q)$(MAKE) -C src BIN_NAME=$(BIN_NAME)

$(BINARY): build

# ---------------------------------------------------------------- tests

test check: build
	$(Q)tests/run_tests.sh

lint:
	$(Q)for f in $(SHELLS); do \
	    bash -n "$$f" || exit 1; \
	    echo "  BASH  $$f ok"; \
	done
	$(Q)command -v shellcheck >/dev/null 2>&1 \
	    && shellcheck -S warning $(SHELLS) && echo "  SHCK  ok" \
	    || echo "  SHCK  shellcheck not installed, skipped"

# A real dialog on your own display, handy after changing the stylesheet.
run demo: build
	$(Q)./$(BINARY) --timeout 20 82.4 75 "$$(hostname)"

# ------------------------------------------------------------- packaging

deps:
	$(Q)if [ "$$(id -u)" -ne 0 ]; then \
	    echo "make deps installs packages, run it as root (sudo make deps)" >&2; \
	    exit 1; \
	fi
	$(Q)if command -v apt-get >/dev/null 2>&1; then \
	    apt-get update && apt-get install -y build-essential pkg-config qtbase5-dev; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y gcc-c++ make pkgconf-pkg-config qt5-qtbase-devel; \
	elif command -v pacman >/dev/null 2>&1; then \
	    pacman -S --needed --noconfirm base-devel pkgconf qt5-base; \
	else \
	    echo "unknown package manager, install a C++ compiler and the Qt5 widgets headers" >&2; \
	    exit 1; \
	fi

install: build
	@echo "  INST  $(DESTDIR)$(BINDIR)/$(BIN_NAME)"
	$(Q)$(INSTALL) -d "$(DESTDIR)$(BINDIR)"
	$(Q)$(INSTALL) -m 0755 $(BINARY) "$(DESTDIR)$(BINDIR)/$(BIN_NAME)"
	$(Q)for name in $(ALIASES); do \
	    ln -sf $(BIN_NAME) "$(DESTDIR)$(BINDIR)/$$name"; \
	    echo "  LN    $(DESTDIR)$(BINDIR)/$$name -> $(BIN_NAME)"; \
	done
	@echo "  INST  $(DESTDIR)$(BINDIR)/qtnotify-broadcast"
	$(Q)$(INSTALL) -m 0755 $(BROADCAST) "$(DESTDIR)$(BINDIR)/qtnotify-broadcast"
	$(Q)for size in $(ICON_SIZES); do \
	    $(INSTALL) -d "$(DESTDIR)$(ICONDIR)/$${size}x$${size}/apps"; \
	    $(INSTALL) -m 0644 assets/icons/qtnotify-$$size.png \
	        "$(DESTDIR)$(ICONDIR)/$${size}x$${size}/apps/qtnotify.png"; \
	done
	$(Q)$(INSTALL) -d "$(DESTDIR)$(ICONDIR)/scalable/apps"
	$(Q)$(INSTALL) -m 0644 assets/icons/qtnotify.svg \
	    "$(DESTDIR)$(ICONDIR)/scalable/apps/qtnotify.svg"
	@echo "  INST  $(DESTDIR)$(ICONDIR)/*/apps/qtnotify.*"
	$(Q)$(INSTALL) -d "$(DESTDIR)$(DOCDIR)"
	$(Q)$(INSTALL) -m 0644 README.md "$(DESTDIR)$(DOCDIR)/README.md"
	@echo "  INST  $(DESTDIR)$(DOCDIR)/README.md"

uninstall:
	$(Q)rm -f "$(DESTDIR)$(BINDIR)/$(BIN_NAME)" \
	          "$(DESTDIR)$(BINDIR)/qtnotify-broadcast"
	$(Q)for name in $(ALIASES); do rm -f "$(DESTDIR)$(BINDIR)/$$name"; done
	$(Q)for size in $(ICON_SIZES); do \
	    rm -f "$(DESTDIR)$(ICONDIR)/$${size}x$${size}/apps/qtnotify.png"; \
	done
	$(Q)rm -f "$(DESTDIR)$(ICONDIR)/scalable/apps/qtnotify.svg"
	$(Q)rm -rf "$(DESTDIR)$(DOCDIR)"
	@echo "  RM    $(BIN_NAME), aliases, qtnotify-broadcast, icons, docs"

# Icons are committed, this only needs running after editing the artwork.
assets:
	$(Q)command -v python3 >/dev/null 2>&1 \
	    || { echo "python3 is needed to re-render the icons" >&2; exit 1; }
	$(Q)python3 assets/icons/make_icons.py --out-dir assets/icons \
	    --sizes $(ICON_SIZES_CSV)

dist: distclean
	$(Q)mkdir -p dist
	$(Q)tar --exclude-vcs --exclude=dist --exclude=bin --exclude=obj \
	    -czf dist/$(PACKAGE)-$(VERSION).tar.gz \
	    --transform 's,^\.,$(PACKAGE)-$(VERSION),' .
	@echo "  TAR   dist/$(PACKAGE)-$(VERSION).tar.gz"

clean:
	$(Q)$(MAKE) -C src clean BIN_NAME=$(BIN_NAME)
	$(Q)rm -rf bin obj

distclean: clean
	$(Q)rm -rf dist

help:
	@sed -n '3,12p' Makefile | sed 's/^# \{0,1\}//'
	@echo
	@echo "Current settings: PREFIX=$(PREFIX) DESTDIR=$(DESTDIR) VERSION=$(VERSION)"
