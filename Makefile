# Build output lives outside the repo: codesign rejects the extended attributes that
# synced folders (like an iCloud Desktop) add to files.
DERIVED := $(HOME)/Library/Caches/Delta/DerivedData
APP := $(DERIVED)/Build/Products/Release/Delta.app
XCODEBUILD := xcodebuild -project Delta.xcodeproj -scheme Delta -derivedDataPath $(DERIVED)

.PHONY: project build test run install dmg release icon clean

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

# Bumps the version in project.yml, runs the tests, commits, tags and pushes.
# Pushing the tag makes GitHub Actions build the .dmg and publish the release.
#   make release VERSION=0.2.0
release:
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "Usage: make release VERSION=x.y.z"; exit 1; }
	@test "$$(git branch --show-current)" = main || { echo "Releases are made from main"; exit 1; }
	@git diff --quiet && git diff --cached --quiet || { echo "Commit or stash your changes first"; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || { echo "Tag v$(VERSION) already exists"; exit 1; }
	git pull --ff-only
	sed -i '' -E 's/MARKETING_VERSION: "[^"]*"/MARKETING_VERSION: "$(VERSION)"/' project.yml
	build=$$(awk -F'"' '/CURRENT_PROJECT_VERSION/ {print $$2; exit}' project.yml); \
	  sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$$((build + 1))\"/" project.yml
	$(MAKE) test
	git commit -am "Release v$(VERSION)"
	git tag "v$(VERSION)"
	git push origin main "v$(VERSION)"
	@echo "Pushed v$(VERSION). The release appears at https://github.com/syedwaleedhyder/delta/releases once the Release workflow finishes (about 3 minutes)."

icon:
	swift scripts/make-icon.swift Sources/Resources/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf "$(DERIVED)" dist Delta.xcodeproj
