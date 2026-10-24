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

.PHONY: build release test example run restore clean app icon icon-source plates plates-source zip dist notarize install uninstall print-version engine plugins helpers
build: engine plugins helpers plates
	swift build $(QUIET)

release: engine plugins helpers plates
	swift build -c release $(QUIET)

test: engine plugins
	swift test $(TEST_FLAGS) $(QUIET)

# `config.example.toml` is generated from the settings' schema and pinned by a test; this rewrites it, and
# the diff to read is `git diff`. CI never sets the variable, so a stale file fails the suite there.
example:
	DOCK2_UPDATE_GOLDEN=1 swift test $(TEST_FLAGS) --filter theExampleIsTheDefaultsAndMatchesItsGolden $(QUIET)
	@git --no-pager diff --stat -- config.example.toml

# --- Helpers -----------------------------------------------------------------------------------
# Now Playing's reader, a library /usr/bin/perl loads (Helpers/now-playing): beside the executable
# in .build, in Resources/Helpers in the bundle.
HELPERS_OUT := .build/helpers

helpers: $(HELPERS_OUT)/libdock2nowplaying.dylib $(HELPERS_OUT)/nowplaying.pl

$(HELPERS_OUT)/libdock2nowplaying.dylib: Helpers/now-playing/nowplaying.m
	@mkdir -p $(HELPERS_OUT)
	xcrun clang -fobjc-arc -Wno-deprecated-declarations -dynamiclib -framework Foundation -o $@ $<
	codesign --force --sign - $@

$(HELPERS_OUT)/nowplaying.pl: Helpers/now-playing/nowplaying.pl
	@mkdir -p $(HELPERS_OUT)
	cp $< $@

# --- The Finder tile's plates ------------------------------------------------------------------
# What the Finder tile's own icon is drawn on: Icon Composer's, written to `Resources/Plates` by
# `Resources/plates.py`, which needs Xcode. Beside the executable in .build, in Resources/Plates in the bundle.
PLATES_OUT := .build/plates
PLATES     := $(wildcard Resources/Plates/*.png)

plates: $(PLATES:Resources/Plates/%=$(PLATES_OUT)/%)

$(PLATES_OUT)/%.png: Resources/Plates/%.png
	@mkdir -p $(PLATES_OUT)
	cp $< $@

plates-source:
	uv run Resources/plates.py

# --- The plugin engine -------------------------------------------------------------------------
# SwiftPM cannot run cargo: the engine's static library is built here and wrapped as the XCFramework
# Package.swift names as a binary target. Cargo is incremental, so an unchanged engine costs a moment.
ENGINE     := Engine
ENGINE_LIB := $(ENGINE)/target/dock2/libdockwasm.a
ENGINE_XCF := Frameworks/DockWasm.xcframework

engine: $(ENGINE_XCF)

$(ENGINE_LIB): $(wildcard $(ENGINE)/src/*.rs) $(ENGINE)/Cargo.toml
	cargo build --profile dock2 --manifest-path $(ENGINE)/Cargo.toml

$(ENGINE_XCF): $(ENGINE_LIB) $(wildcard $(ENGINE)/include/*)
	rm -rf $@
	xcodebuild -create-xcframework -library $(ENGINE_LIB) -headers $(ENGINE)/include -output $@ >/dev/null

# --- Plugins -----------------------------------------------------------------------------------
# The crates in Plugins/ are one Cargo workspace built to WebAssembly; each but the SDK is assembled,
# with its manifest, as .build/plugins/<id>.dock2plugin: where a development run looks, and what `app`
# copies into the bundle. The tests' guest builds the same way into .build/test-plugins.
PLUGINS_OUT := .build/plugins
WASM_OUT    := Plugins/target/wasm32-unknown-unknown/release

plugins:
	cargo build --release --target wasm32-unknown-unknown --manifest-path Plugins/Cargo.toml --workspace --quiet
	@mkdir -p $(PLUGINS_OUT) .build/test-plugins
	@for dir in $(dir $(wildcard Plugins/*/manifest.json)); do \
	  id=$$(plutil -extract id raw -o - $$dir/manifest.json) || exit 1; \
	  crate=$$(basename $$dir | tr - _); \
	  out=$$([ "$$id" = "zip.tanner.dock2.test-guest" ] && echo .build/test-plugins || echo $(PLUGINS_OUT))/$$id.dock2plugin; \
	  rm -rf $$out; mkdir -p $$out; \
	  cp $$dir/manifest.json $$out/; \
	  cp $(WASM_OUT)/$$crate.wasm $$out/plugin.wasm; \
	  if [ -d $$dir/assets ]; then cp -R $$dir/assets/. $$out/; fi; \
	done

# Runs in this terminal: Ctrl-C quits it, which puts the system Dock back.
run: build
	.build/debug/dock2

# The escape hatch: puts the system Dock back if a dock2 that is no longer running left it hidden.
restore: build
	.build/debug/dock2 --restore

clean:
	swift package clean
	rm -rf $(ENGINE_XCF)
	rm -rf $(DIST)

# --- Version -------------------------------------------------------------------------------------
# The git tag is the only version authority; nothing in the tree carries a number. `app` stamps it
# into the bundle's *copy* of the plist, never the source, and `dock2Version` reads it back.
GIT_DESCRIBE := $(shell git describe --tags --match 'v[0-9]*' --dirty 2>/dev/null)
VERSION      ?= $(if $(GIT_DESCRIBE),$(patsubst v%,%,$(GIT_DESCRIBE)),0.0.0)
BUILD        ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

print-version:
	@echo $(VERSION)

# --- Dock2.app -----------------------------------------------------------------------------------
# Assembled by hand rather than by Xcode: SwiftPM produces the executable and this copies it next to
# an Info.plist. The one executable is the app, `--restore`, and the guard (`--guard <pid>`), which
# dock2 starts from its own path — so the guard is always the same build as the dock it watches.
#
# The bundle and its `CFBundleName`, the name people see, are `Dock2`; the executable inside stays `dock2`.
#
# Signing defaults to ad-hoc (`--sign -`); `CODESIGN_IDENTITY` overrides it with a Developer ID, which
# brings the hardened runtime and a secure timestamp with it.
APP_NAME    := dock2
BUNDLE_NAME := Dock2.app
DIST        := dist
BUNDLE      := $(DIST)/$(BUNDLE_NAME)
CONTENTS    := $(BUNDLE)/Contents
RELEASE     := .build/release

CODESIGN_IDENTITY ?= -
ifeq ($(CODESIGN_IDENTITY),-)
  SIGN_FLAGS :=
else
  SIGN_FLAGS := --options runtime --timestamp
endif

# --- The app icon ------------------------------------------------------------------------------
# `Resources/dock2.icon` is an Icon Composer document, written by `Resources/icon.py`. actool, which is
# in Xcode and not the Command Line Tools, compiles it to `Assets.car` and `dock2.icns`; a CLT-only build
# skips the icon. `xcrun --find` is the probe, since `/usr/bin/actool` exists either way.
ICON   := Resources/$(APP_NAME).icon
ACTOOL := $(shell xcrun --find actool 2>/dev/null)

icon:
ifeq ($(ACTOOL),)
	@echo "warning: no actool — needs Xcode, not Command Line Tools. Bundle gets no icon."
else
	@$(ACTOOL) $(ICON) --compile $(CONTENTS)/Resources \
		--app-icon $(APP_NAME) --include-all-app-icons \
		--platform macosx --target-device mac \
		--minimum-deployment-target 26.0 --development-region en \
		--output-partial-info-plist $(DIST)/icon-partial.plist \
		--output-format human-readable-text --notices --warnings --errors
endif

icon-source:
	uv run Resources/icon.py

app: release
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	@$(MAKE) --no-print-directory icon
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	                        -c "Set :CFBundleVersion $(BUILD)" $(CONTENTS)/Info.plist
	cp $(RELEASE)/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME)
	mkdir -p $(CONTENTS)/Resources/Plugins $(CONTENTS)/Resources/Helpers $(CONTENTS)/Resources/Plates
	cp -R $(PLUGINS_OUT)/. $(CONTENTS)/Resources/Plugins/
	cp $(PLATES_OUT)/*.png $(CONTENTS)/Resources/Plates/
	cp $(HELPERS_OUT)/libdock2nowplaying.dylib $(HELPERS_OUT)/nowplaying.pl $(CONTENTS)/Resources/Helpers/
	# Inside out: notarization wants every Mach-O signed, the helper perl loads among them.
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(SIGN_FLAGS) $(CONTENTS)/Resources/Helpers/libdock2nowplaying.dylib
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

# Apple's notary service, for a Developer ID build: `NOTARY_PROFILE` names a keychain profile made once with
# `xcrun notarytool store-credentials`, in `NOTARY_KEYCHAIN` if given, else the login keychain. The ticket
# is stapled to the app, then the zip is made again.
notarize: app zip
	@test "$(CODESIGN_IDENTITY)" != "-" || { echo "notarize needs CODESIGN_IDENTITY, a Developer ID"; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "notarize needs NOTARY_PROFILE"; exit 1; }
	xcrun notarytool submit $(ZIP) --keychain-profile "$(NOTARY_PROFILE)" \
		$(if $(NOTARY_KEYCHAIN),--keychain "$(NOTARY_KEYCHAIN)") --wait
	xcrun stapler staple $(BUNDLE)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(BUNDLE) $(ZIP)
	@shasum -a 256 $(ZIP)

install: app
	rm -rf /Applications/$(BUNDLE_NAME)
	cp -R $(BUNDLE) /Applications/
	@echo "installed /Applications/$(BUNDLE_NAME) — quit it from the platter's right-click menu"

uninstall:
	rm -rf /Applications/$(BUNDLE_NAME)
