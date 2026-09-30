# src/Makefile
#
# Builds the qtnotify binary. Driven by the top level Makefile, but works
# on its own too:
#
#   make -C src                 build ../bin/qtnotify
#   make -C src clean           remove ../obj and the binary
#   make -C src DEBUG=1         -O0 -g, assertions on
#   make -C src V=1             echo every command
#
# No moc pass is needed, there is no QObject subclass in the source. The
# only generated file is the Qt resource for the window icon, produced by
# rcc from ../assets/qtnotify.qrc. If rcc is not installed the binary is
# still built, just without an embedded icon.

TOP       := ..
BIN_DIR   := $(TOP)/bin
OBJ_DIR   := $(TOP)/obj
ASSET_DIR := $(TOP)/assets

BIN_NAME  ?= qtnotify
TARGET    := $(BIN_DIR)/$(BIN_NAME)

SOURCES   := tempmon_alert.cpp
QRC       := $(ASSET_DIR)/qtnotify.qrc
QRC_SRC   := $(OBJ_DIR)/qrc_qtnotify.cpp
ASSETS    := $(wildcard $(ASSET_DIR)/icons/*.png) $(wildcard $(ASSET_DIR)/icons/*.svg)

PKG_CONFIG ?= pkg-config
QT_PKGS    := Qt5Widgets

# rcc is called rcc, rcc-qt5 or lives in the Qt bindir depending on the
# distribution. Empty means "build without resources".
RCC ?= $(firstword $(wildcard \
         $(shell command -v rcc 2>/dev/null) \
         $(shell command -v rcc-qt5 2>/dev/null) \
         /usr/lib/qt5/bin/rcc \
         /usr/lib/*/qt5/bin/rcc))

QT_CFLAGS := $(shell $(PKG_CONFIG) --cflags $(QT_PKGS) 2>/dev/null)
QT_LIBS   := $(shell $(PKG_CONFIG) --libs $(QT_PKGS) 2>/dev/null)

CXX      ?= g++
CXXSTD   ?= -std=c++17
WARNINGS ?= -Wall -Wextra -Wpedantic -Wshadow
OPTFLAGS ?= -O2 -DNDEBUG

ifdef DEBUG
OPTFLAGS := -O0 -g3 -fno-omit-frame-pointer
endif

CXXFLAGS ?=
CXXFLAGS += $(CXXSTD) $(WARNINGS) $(OPTFLAGS) -fPIC $(QT_CFLAGS)
LDFLAGS  ?=
LDLIBS   += $(QT_LIBS)

OBJECTS := $(addprefix $(OBJ_DIR)/,$(SOURCES:.cpp=.o))

ifneq ($(strip $(RCC)),)
OBJECTS += $(OBJ_DIR)/qrc_qtnotify.o
endif

DEPS := $(OBJECTS:.o=.d)

# make V=1 shows the full command lines.
ifeq ($(V),1)
Q :=
else
Q := @
endif

.PHONY: all clean check-qt

all: $(TARGET)

$(TARGET): $(OBJECTS) | $(BIN_DIR) check-qt
	@echo "  LD    $@"
	$(Q)$(CXX) $(LDFLAGS) -o $@ $(OBJECTS) $(LDLIBS)

$(OBJ_DIR)/qrc_qtnotify.o: $(QRC_SRC) | $(OBJ_DIR) check-qt
	@echo "  CXX   $<"
	$(Q)$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

# Resources are regenerated when the .qrc or any icon under assets changes.
$(QRC_SRC): $(QRC) $(ASSETS) | $(OBJ_DIR)
	@echo "  RCC   $(QRC)"
	$(Q)$(RCC) --name qtnotify $(QRC) -o $@

$(OBJ_DIR)/%.o: %.cpp | $(OBJ_DIR) check-qt
	@echo "  CXX   $<"
	$(Q)$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(BIN_DIR) $(OBJ_DIR):
	$(Q)mkdir -p $@

# Fails early with an actionable message instead of a wall of missing
# header errors. Order only prerequisite, so it never forces a rebuild.
check-qt:
	$(Q)$(PKG_CONFIG) --exists $(QT_PKGS) 2>/dev/null || { \
	    echo "error: Qt5 development files not found (pkg-config $(QT_PKGS))" >&2; \
	    echo "  Debian/Ubuntu/Raspberry Pi OS: sudo apt-get install -y build-essential qtbase5-dev" >&2; \
	    echo "  Fedora:                        sudo dnf install -y gcc-c++ qt5-qtbase-devel" >&2; \
	    echo "  Arch:                          sudo pacman -S --needed base-devel qt5-base" >&2; \
	    exit 1; }

clean:
	$(Q)rm -f $(OBJECTS) $(DEPS) $(QRC_SRC) $(TARGET)
	$(Q)rmdir $(OBJ_DIR) $(BIN_DIR) 2>/dev/null || true

-include $(DEPS)
