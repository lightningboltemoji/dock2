# dock2 build entry points: the Swift build + test loop, and the app bundle dock2 ships in.

# --- Swift Testing toolchain wiring -----------------------------------------------------------
# Under a full Xcode or a swift.org toolchain, `swift test` runs Swift Testing out of the box.
# A CommandLineTools-only install ships Testing.framework + libTestingMacros.dylib but doesn't
# wire them into SwiftPM's explicit-module test build, so we load the macro plugin and add the
# framework/interop rpaths explicitly. We detect that case by probing for the CLT plugin; when
# it's absent (i.e. Xcode is active) TEST_FLAGS stays empty and `swift test` runs unmodified.
DEVDIR          := $(shell xcode-select -p 2>/dev/null)
TESTING_PLUGIN  := $(DEVDIR)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
TESTING_FWK     := $(DEVDIR)/Library/Developer/Frameworks
TESTING_INTEROP := $(DEVDIR)/Library/Developer/usr/lib

ifeq ($(wildcard $(TESTING_PLUGIN)),)
  TEST_FLAGS :=
else
  TEST_FLAGS := -Xswiftc -load-plugin-library -Xswiftc $(TESTING_PLUGIN) \
                -Xlinker -rpath -Xlinker $(TESTING_FWK) \
                -Xlinker -rpath -Xlinker $(TESTING_INTEROP)
endif

# --- Linker search-path noise -------------------------------------------------------------------
# The same CLT-only install makes SwiftPM pass search paths that only exist inside Xcode.app, so ld
# warns once per target. Filter exactly those lines, on stderr only; a redirect rather than a pipe
# keeps the exit status. Requires bash for `>(...)`.
SHELL   := /bin/bash
LD_NOISE = ld: warning: search path '$(DEVDIR)/Developer/.*' not found
QUIET    = 2> >(grep -vE "$(LD_NOISE)" >&2)

.PHONY: build release test run restore clean app zip dist install uninstall print-version
build:
	swift build $(QUIET)

release:
	swift build -c release $(QUIET)

test:
	swift test $(TEST_FLAGS) $(QUIET)

# Runs in this terminal: Ctrl-C quits it, which puts the system Dock back.
run: build
	.build/debug/dock2

# The escape hatch: puts the system Dock back if a dock2 that is no longer running left it hidden.
restore: build
	.build/debug/dock2 --restore

clean:
	swift package clean
	rm -rf $(DIST)

# --- Version -------------------------------------------------------------------------------------
# The git tag is the only version authority; nothing in the tree carries a number. `app` stamps it
# into the bundle's *copy* of the plist, never the source, and `dock2Version` reads it back.
GIT_DESCRIBE := $(shell git describe --tags --match 'v[0-9]*' --dirty 2>/dev/null)
VERSION      ?= $(if $(GIT_DESCRIBE),$(patsubst v%,%,$(GIT_DESCRIBE)),0.0.0)
BUILD        ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

print-version:
	@echo $(VERSION)

# --- dock2.app -----------------------------------------------------------------------------------
# Assembled by hand rather than by Xcode: SwiftPM produces the executable and this copies it next to
# an Info.plist. The one executable is the app, `--restore`, and the guard (`--guard <pid>`), which
# dock2 starts from its own path — so the guard is always the same build as the dock it watches.
#
# Signing defaults to ad-hoc (`--sign -`); `CODESIGN_IDENTITY` overrides it with a Developer ID, which
# brings the hardened runtime and a secure timestamp with it.
APP_NAME := dock2
DIST     := dist
BUNDLE   := $(DIST)/$(APP_NAME).app
CONTENTS := $(BUNDLE)/Contents
RELEASE  := .build/release

CODESIGN_IDENTITY ?= -
ifeq ($(CODESIGN_IDENTITY),-)
  SIGN_FLAGS :=
else
  SIGN_FLAGS := --options runtime --timestamp
endif

app: release
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	                        -c "Set :CFBundleVersion $(BUILD)" $(CONTENTS)/Info.plist
	cp $(RELEASE)/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME)
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(SIGN_FLAGS) $(BUNDLE)
	@echo "built $(BUNDLE) — version $(VERSION) ($(BUILD))"

# `ditto`, not `zip`: a bundle carries symlinks, xattrs and a signature that plain zip mangles.
ZIP_NAME ?= $(APP_NAME)-$(VERSION).zip
ZIP      := $(DIST)/$(ZIP_NAME)

zip:
	rm -f $(ZIP)
	ditto -c -k --keepParent $(BUNDLE) $(ZIP)
	@shasum -a 256 $(ZIP)

dist: app zip

install: app
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUNDLE) /Applications/
	@echo "installed /Applications/$(APP_NAME).app — quit it from the platter's right-click menu"

uninstall:
	rm -rf /Applications/$(APP_NAME).app
