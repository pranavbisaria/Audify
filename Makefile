# Audify — build, bundle, sign and install.
#
# `make install` is the one command most people want: it produces a signed
# Audify.app and copies it into /Applications.

APP_NAME     := Audify
BUNDLE_ID    := com.audify.mixer
DIST         := dist
APP          := $(DIST)/$(APP_NAME).app
CONTENTS     := $(APP)/Contents
BUILD_DIR    := build
CONFIG       := release

# Universal by default so the same bundle runs on Apple silicon and Intel.
ARCHS        := --arch arm64 --arch x86_64
PRODUCT_DIR  := .build/apple/Products/Release

# Ad-hoc by default. Override for a distributable build, e.g.
#   make bundle SIGN_ID="Developer ID Application: You (TEAMID)"
SIGN_ID      ?= -

.DEFAULT_GOAL := help
.PHONY: help build bundle sign install uninstall run diagnose test icon dmg clean relaunch

help:
	@echo "Audify"
	@echo "  make build      Compile (universal, release)"
	@echo "  make bundle     Build Audify.app into ./$(DIST)"
	@echo "  make install    Bundle, then install into /Applications and launch"
	@echo "  make run        Bundle and run from ./$(DIST)"
	@echo "  make diagnose   Print the audio graph Audify sees"
	@echo "  make test       Run unit tests"
	@echo "  make dmg        Build a distributable disk image"
	@echo "  make uninstall  Remove the app, its login item and its settings"
	@echo "  make clean      Delete build products"
	@echo ""
	@echo "  Signing: make bundle SIGN_ID=\"Developer ID Application: NAME (TEAM)\""

build:
	swift build -c $(CONFIG) $(ARCHS)

test:
	swift test

icon: $(BUILD_DIR)/AppIcon.icns Extension/icons/icon128.png

$(BUILD_DIR)/AppIcon.icns: Tools/makeicon.swift
	@mkdir -p $(BUILD_DIR)
	swift Tools/makeicon.swift $(BUILD_DIR)/AppIcon.iconset
	iconutil -c icns -o $@ $(BUILD_DIR)/AppIcon.iconset

Extension/icons/icon128.png: Tools/makeicon.swift
	swift Tools/makeicon.swift --extension Extension/icons

bundle: build icon
	@rm -rf $(APP)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(PRODUCT_DIR)/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp $(BUILD_DIR)/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@# Ship the browser extension inside the bundle so Settings can reveal it.
	@cp -R Extension $(CONTENTS)/Resources/Extension
	@$(MAKE) --no-print-directory sign
	@echo "Built $(APP)"
	@echo "Architectures: $$(lipo -archs $(CONTENTS)/MacOS/$(APP_NAME))"

sign:
	@# The hardened runtime is required for notarisation and is what makes the
	@# audio-input entitlement meaningful.
	@codesign --force --deep --options runtime --timestamp=none \
		--entitlements Resources/Audify.entitlements \
		--sign "$(SIGN_ID)" $(APP)
	@codesign --verify --verbose=1 $(APP) 2>&1 | sed 's/^/  /'
	@if [ "$(SIGN_ID)" = "-" ]; then \
		echo "  note: ad-hoc signed. Fine for local use; macOS will ask for audio"; \
		echo "        permission again after each rebuild, and Launch at Login may"; \
		echo "        need approving in System Settings."; \
	fi

install: bundle
	@echo "Installing to /Applications…"
	@osascript -e 'quit app "Audify"' 2>/dev/null || true
	@sleep 1
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP) /Applications/
	@open /Applications/$(APP_NAME).app
	@echo "Audify is running — look for the fader icon in the menu bar."

run: bundle
	@osascript -e 'quit app "Audify"' 2>/dev/null || true
	@sleep 1
	@open $(APP)

relaunch:
	@osascript -e 'quit app "Audify"' 2>/dev/null || true
	@sleep 1
	@open /Applications/$(APP_NAME).app

diagnose: bundle
	@$(CONTENTS)/MacOS/$(APP_NAME) --diagnose

dmg: bundle
	@rm -f $(DIST)/$(APP_NAME).dmg
	@mkdir -p $(BUILD_DIR)/dmg
	@rm -rf $(BUILD_DIR)/dmg/*
	@cp -R $(APP) $(BUILD_DIR)/dmg/
	@ln -s /Applications $(BUILD_DIR)/dmg/Applications
	@hdiutil create -volname "$(APP_NAME)" -srcfolder $(BUILD_DIR)/dmg \
		-ov -format UDZO $(DIST)/$(APP_NAME).dmg
	@echo "Built $(DIST)/$(APP_NAME).dmg"

uninstall:
	@osascript -e 'quit app "Audify"' 2>/dev/null || true
	@rm -rf /Applications/$(APP_NAME).app
	@defaults delete $(BUNDLE_ID) 2>/dev/null || true
	@echo "Removed Audify. Its entry under Privacy & Security ▸ Audio Recording"
	@echo "can be cleared manually if you want a completely clean slate."

clean:
	@rm -rf .build $(BUILD_DIR) $(DIST)
	@echo "Cleaned."
