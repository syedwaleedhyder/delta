# AGENTS.md

Guide for AI agents working on **Delta — Diff Viewer**, a native macOS app (Swift 6 + SwiftUI) that compares two pasted texts. Markdown is the first format; the app is named generically so other formats can be added later.

Repo: https://github.com/syedwaleedhyder/delta (public).

## Commands

```bash
make test                     # generate project + run unit tests (do this before every commit)
make run                      # Release build + launch
make install                  # build and copy to /Applications (no Gatekeeper prompt for local builds)
make dmg                      # build dist/Delta-<version>.dmg locally (ad-hoc signed)
make release VERSION=x.y.z    # bump version, test, commit, tag, push → GitHub publishes the .dmg
make icon                     # regenerate the app icon from scripts/make-icon.swift
```

Requires Xcode 16+ and XcodeGen (`brew install xcodegen`).

## Layout

| Path | What it does |
|---|---|
| `project.yml` | XcodeGen spec. **The `.xcodeproj` is generated and git-ignored**. Edit this file, never the project. |
| `Sources/App/DeltaApp.swift` | `@main`, single `Window`, menus and keyboard shortcuts, About panel |
| `Sources/Model/AppState.swift` | `@MainActor ObservableObject`: input text (saved to UserDefaults), view options, debounced background diffing, change navigation |
| `Sources/Model/DiffEngine.swift` | Line diff: patience anchors on lines unique to both sides, Myers (`CollectionDifference`) between them. Changed lines are paired by similarity, then word-diffed. Pure functions; covered by tests. |
| `Sources/Model/DiffModel.swift` | `DiffResult`, `DiffRow` (side-by-side), `InlineRow`, `Segment` |
| `Sources/Rendering/RenderedDiff.swift` | Markdown → HTML (swift-markdown), then a diff over HTML tokens that wraps changes in `<ins>`/`<del>`. Also builds the page (CSP + nonce script for navigation). |
| `Sources/Resources/diff.css` | Rendered-view styles (light/dark) |
| `Sources/Views/` | `ContentView` (layout, toolbar, status bar), `InputEditor` (NSTextView paste box), `RawDiffView`, `RenderedDiffView` (WKWebView) |
| `Tests/DiffEngineTests.swift` | Unit tests for both diff engines |
| `scripts/release.sh` | Build → sign → `.dmg` (used by `make dmg` and CI) |
| `.github/workflows/` | `ci.yml` (tests on push/PR to main), `release.yml` (on `v*` tag: test, build .dmg, publish GitHub Release) |

## Releasing a new version

1. Make sure `main` holds everything for the release and `make test` passes.
2. Pick the version using semver: patch for fixes, minor for features.
3. Run `make release VERSION=x.y.z`. It refuses to run off `main`, with uncommitted changes, or if the tag already exists. It then:
   - bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`
   - runs the tests
   - commits "Release vx.y.z", tags `vx.y.z` and pushes both.
4. The tag triggers `.github/workflows/release.yml`. In about 3 minutes, `Delta-x.y.z.dmg` is attached to a GitHub Release with auto-generated notes. Check with `gh run list --limit 2` and `gh release view vx.y.z`.
5. If the workflow fails, fix the problem on `main`, then move the tag to the fix:
   - `git tag -d vx.y.z && git push origin :refs/tags/vx.y.z`
   - re-tag the fixed commit and push the tag.

   Do this only if no release was published. Never rewrite a published release; ship a new patch version instead.

Users install from the `.dmg` and approve the app once under System Settings → Privacy & Security → "Open Anyway". There is **no Apple Developer account**, so the app is ad-hoc signed and not notarized. `scripts/release.sh` already supports `SIGN_IDENTITY` and `NOTARY_PROFILE` if an account is added later. If that happens, also update the README's install section.

## Gotchas (learned the hard way)

- **Build output must live outside the repo.** The repo is on an iCloud-synced Desktop, and `codesign` fails there with "resource fork, Finder information, or similar detritus not allowed". The Makefile and release script use `~/Library/Caches/Delta/DerivedData`. Always pass `-derivedDataPath` to `xcodebuild`, or use the make targets.
- **After adding or removing source files, run `xcodegen generate`** (every make target does this). Otherwise new files, including tests, are silently left out of the build. "Executed 0 tests" means you forgot.
- **Editor (SourceKit) diagnostics such as "Cannot find X in scope" are noise** in this setup, because files are checked without the generated project. Trust `xcodebuild` output.
- **Swift 6 language mode** is on, with strict concurrency. Keep the engines `Sendable` and nonisolated, and UI or state types `@MainActor`.
- **The Swift 6.4 compiler crashes** ("failed to produce diagnostic") on a ternary that mixes a function reference with a closure, and on `by: ==` passed to a generic function. Write explicit closures, e.g. `{ $0 == $1 }`.
- **The next/previous change shortcuts are ⌥⌘↓ / ⌥⌘↑ on purpose.** Plain ⌘↓ would be taken over from the text editors, where it means "go to end".
- **Rendered-view safety:** pasted Markdown can contain raw HTML. The page's CSP allows only scripts that carry the per-page nonce. Keep it that way; don't add `'unsafe-inline'` to `script-src`.
- **swift-markdown wraps list items in `<p>`.** The CSS removes their margins (`li > p`).
- **Screenshots:** the terminal has no Screen Recording permission, so `screencapture` of the app window fails. To check UI visually:
  - write a temporary XCTest that renders views with SwiftUI `ImageRenderer` (use `VStack`, not `LazyVStack`), or that writes `RenderedDiff.page(...)` to an HTML file
  - serve that file over `python3 -m http.server` on localhost and open it in the browser pane
  - delete the temporary test afterwards.

## Conventions

- Match the surrounding style: small types, comments only where the *why* isn't obvious, no force-unwraps outside tests and scripts.
- Add or extend tests in `Tests/` for any diff-engine change. UI changes need a visual check (see above).
- Diffing runs off the main thread (`Task.detached` in `AppState.recompute`). Keep the engines free of UI types.
- New formats (e.g. JSON, code) should plug in next to `RenderedDiff` and reuse `DiffEngine.ops` / `tokenize`, rather than adding a second diff algorithm.
- Commit to `main` in small, descriptive commits. CI must stay green.
