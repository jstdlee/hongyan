#!/usr/bin/env bash
# Build, test and release Hongyan on a Mac (Xcode 26.1+). No GitHub Actions needed.
#
#   scripts/mac.sh setup            install xcodegen + xcbeautify (Homebrew), generate the project
#   scripts/mac.sh test             run the HongyanCore tests on an iPhone Simulator
#   scripts/mac.sh build            build app + extension for the Simulator and for a device
#   scripts/mac.sh shots            demo-mode screenshots into docs/gallery
#   scripts/mac.sh ipa v0.3.0       unsigned IPA + checksum in dist/
#   scripts/mac.sh release v0.3.0   test, IPA, notes from CHANGELOG.md, tag, GitHub release page
#   scripts/mac.sh all              setup, test, build, shots
#
# Optional: HONGYAN_UPLOAD_URL_BASE=https://<account>.r2.cloudflarestorage.com scripts/mac.sh ipa v0.3.0
set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD_BASE="${HONGYAN_UPLOAD_URL_BASE:-https://ACCOUNT_ID.r2.cloudflarestorage.com}"
pretty() { if command -v xcbeautify >/dev/null; then xcbeautify; else cat; fi; }

setup() {
  command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
  brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
  brew list xcbeautify >/dev/null 2>&1 || brew install xcbeautify
  xcodebuild -version
  xcodegen generate
}

sim() { scripts/pick-simulator.sh; }

test_core() {
  local udid; udid=$(sim)
  (cd HongyanCore && set -o pipefail && xcodebuild test -scheme HongyanCore -destination "id=$udid" | pretty)
}

build() {
  [ -d Hongyan.xcodeproj ] || xcodegen generate
  local udid; udid=$(sim)
  set -o pipefail
  xcodebuild build -project Hongyan.xcodeproj -scheme Hongyan -destination "id=$udid" \
    -derivedDataPath build/sim CODE_SIGNING_ALLOWED=NO | pretty
  xcodebuild build -project Hongyan.xcodeproj -scheme Hongyan -destination 'generic/platform=iOS' \
    -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO | pretty
}

shots() {
  [ -d build/sim/Build/Products/Debug-iphonesimulator/Hongyan.app ] || build
  scripts/screenshots.sh "$(sim)" build/sim/Build/Products/Debug-iphonesimulator/Hongyan.app docs/gallery
}

ipa() {
  local tag="${1:?usage: scripts/mac.sh ipa vX.Y.Z}"
  [ -d Hongyan.xcodeproj ] || xcodegen generate
  set -o pipefail
  xcodebuild build -project Hongyan.xcodeproj -scheme Hongyan -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/release CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="${tag#v}" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
    HONGYAN_UPLOAD_URL_BASE="$UPLOAD_BASE" | pretty
  rm -rf dist && mkdir -p dist/Payload
  cp -R build/release/Build/Products/Release-iphoneos/Hongyan.app dist/Payload/
  (cd dist && zip -qry "Hongyan-$tag.ipa" Payload && rm -rf Payload)
  (cd dist && shasum -a 256 "Hongyan-$tag.ipa" > "Hongyan-$tag.ipa.sha256")
  ls -la dist
}

notes() { # tag → dist/notes.md (CHANGELOG section + install section)
  local tag="$1"
  awk -v tag="$tag" '/^## / { on = (index($0, "## " tag " ") == 1 || $0 == "## " tag); next } on { print }' \
    CHANGELOG.md > dist/notes.md
  [ -s dist/notes.md ] || { echo "CHANGELOG.md has no section for $tag"; exit 1; }
  cat >> dist/notes.md <<NOTES

## Install

| File | What it is |
|---|---|
| \`Hongyan-$tag.ipa\` | Unsigned app for iPhone (iOS 26.1+) |
| \`Hongyan-$tag.ipa.sha256\` | SHA-256 checksum |

- The IPA is **not signed**. Sign and install it with your own Apple ID (Sideloadly, AltStore), or build from source in Xcode.
- This IPA uploads only under **\`$UPLOAD_BASE\`**. For another endpoint, build from source with \`HONGYAN_UPLOAD_URL_BASE\`.
- Background backup needs the App Group entitlement shared by the app and the extension. Some sideload tools remove it.
NOTES
}

release() {
  local tag="${1:?usage: scripts/mac.sh release vX.Y.Z}"
  [ -z "$(git status --porcelain)" ] || { echo "Commit your changes first."; exit 1; }
  command -v gh >/dev/null || { echo "Install the GitHub CLI: brew install gh"; exit 1; }
  test_core
  ipa "$tag"
  notes "$tag"
  git rev-parse "$tag" >/dev/null 2>&1 || git tag "$tag"
  git push origin "$tag"
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" dist/Hongyan-"$tag".ipa dist/Hongyan-"$tag".ipa.sha256 --clobber
    gh release edit "$tag" --notes-file dist/notes.md
  else
    gh release create "$tag" dist/Hongyan-"$tag".ipa dist/Hongyan-"$tag".ipa.sha256 \
      --title "Hongyan $tag" --notes-file dist/notes.md
  fi
}

case "${1:-}" in
  setup) setup ;;
  test) test_core ;;
  build) build ;;
  shots) shots ;;
  ipa) ipa "${2:-}" ;;
  release) release "${2:-}" ;;
  all) setup; test_core; build; shots ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
