# Build output lives outside the repo: codesign rejects the extended attributes that
# synced folders (like an iCloud Desktop) add to files.
DERIVED := $(HOME)/Library/Caches/Delta/DerivedData
APP := $(DERIVED)/Build/Products/Release/Delta.app
XCODEBUILD := xcodebuild -project Delta.xcodeproj -scheme Delta -derivedDataPath $(DERIVED)

.PHONY: project build test run install dmg icon clean

project:
	xcodegen generate --quiet

build: project
	$(XCODEBUILD) -configuration Release build

test: project
	$(XCODEBUILD) test

run: build
	open "$(APP)"

# Builds locally and copies to /Applications. Locally built apps aren't quarantined,
# so this copy opens without any Gatekeeper prompt.
install: build
	osascript -e 'quit app "Delta"' 2>/dev/null || true
	rm -rf /Applications/Delta.app
	ditto "$(APP)" /Applications/Delta.app
	@echo "Installed /Applications/Delta.app"

dmg: project
	scripts/release.sh

icon:
	swift scripts/make-icon.swift Sources/Resources/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf "$(DERIVED)" dist Delta.xcodeproj
