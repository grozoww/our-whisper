#!/usr/bin/env bash
#
# Builds a distributable OurWhisper.dmg.
#
# Three paths, and which one you get depends on what certificate is available:
#
#   Signed and notarized — needs a paid Apple Developer account. Downloads open with a
#   double-click and no warning. This is what a release should be.
#
#   Self-signed — needs only ./scripts/release-cert.sh. Gatekeeper still refuses the first
#   double-click, so users still need scripts/install.sh. What it buys is the thing ad-hoc
#   signing cannot: a signature whose designated requirement names the *certificate* rather than
#   one exact binary, so the Accessibility grant survives an update instead of silently dying.
#   This is the path this project actually ships on.
#
#   Ad-hoc signed — needs nothing, and costs every user their Accessibility permission on every
#   update. Only for builds nobody installs. See release-cert.sh for why.
#
# Runs in CI (see .github/workflows/release.yml) and locally. Kept as a script rather than inline
# YAML so a release can be reproduced and debugged on a laptop.
#
#   ./scripts/package.sh              the best path the environment below allows
#   ./scripts/package.sh --unsigned   ad-hoc even when a certificate is available
#
# Environment:
#   SIGNING_IDENTITY   certificate to sign with. "OurWhisper Release" for the self-signed path,
#                      "Developer ID Application: Name (TEAMID)" for the notarized one. Left
#                      unset, a local "OurWhisper Release" in the keychain is picked up anyway.
#   APPLE_TEAM_ID      10-character team id          ┐
#   NOTARY_APPLE_ID    Apple ID for notarization     ├ all three, and only all three, add
#   NOTARY_PASSWORD    app-specific password for it  ┘ notarization on top

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OurWhisper"
BUILD_DIR="build/release"
DIST_DIR="dist"
APP="$BUILD_DIR/$APP_NAME.app"

# VERSION, BUILD, SHA and RELEASE_NAME. Derived rather than read out of the project, so the DMG
# filename, the version inside the app and the name on the release page cannot drift apart. See
# scripts/version.sh for how the number is arrived at.
eval "$(./scripts/version.sh)"

# The certificate created by scripts/release-cert.sh. Named here rather than only in that script
# so a hand-run package.sh on the machine that owns the key does not quietly fall back to ad-hoc.
RELEASE_CERT="OurWhisper Release"

# Decide before building: each path produces a different signature, and which one you got cannot
# be worked out afterwards.
#
# "-" is ad-hoc — a real signature with no certificate behind it. Preferred over no signature at
# all, because macOS refuses to run an unsigned arm64 binary outright, but it is the path that
# breaks Accessibility on every update.
if [ "${1:-}" = "--unsigned" ]; then
  IDENTITY="-"
elif [ -n "${SIGNING_IDENTITY:-}" ]; then
  IDENTITY="$SIGNING_IDENTITY"
elif security find-identity -p codesigning 2>/dev/null | grep -q "$RELEASE_CERT"; then
  IDENTITY="$RELEASE_CERT"
else
  IDENTITY="-"
fi

# Notarization is a separate question from signing, and the reason these two used to be one flag
# is the reason releases shipped ad-hoc: with no Apple account there were no notary credentials,
# so the script skipped the certificate too. A self-signed certificate cannot be notarized, and
# does not need to be — it is there for the Accessibility grant, not for Gatekeeper.
NOTARIZE=false
if [ "$IDENTITY" != "-" ] && [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for a notarized build}"
  NOTARIZE=true
fi

# The suffix is what someone scrolling the releases page has to judge a download by, so it says
# which of the three they are getting rather than lumping the last two together.
if [ "$NOTARIZE" = true ]; then
  DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
elif [ "$IDENTITY" != "-" ]; then
  DMG="$DIST_DIR/$APP_NAME-$VERSION-unnotarized.dmg"
  echo "==> Signing with '$IDENTITY'. Not notarized, so Gatekeeper still warns on first open,"
  echo "    but the Accessibility grant will survive updates. See dist/INSTALL.md."
  echo
else
  DMG="$DIST_DIR/$APP_NAME-$VERSION-unsigned.dmg"
  echo "==> No signing certificate. Building an ad-hoc signed DMG."
  echo "    Gatekeeper will warn on first open, AND every user loses their Accessibility"
  echo "    permission on every update. Run ./scripts/release-cert.sh to fix that."
  echo
fi

# scripts/install.sh checks the download against this. It is served from the same host as the
# DMG, so it proves nothing about the publisher — it catches a truncated or corrupted download,
# which over a 100 MB file on a bad connection is the failure people actually hit.
write_checksums() {
  # `./*.dmg` guards against a filename that starts with a dash; the sed drops the prefix again
  # so the file reads the way a SHA256SUMS is expected to.
  (cd "$DIST_DIR" && shasum -a 256 ./*.dmg | sed 's| \./| |' > SHA256SUMS)
  echo "==> Wrote $DIST_DIR/SHA256SUMS"
}

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> Building $APP_NAME $VERSION (build $BUILD, $SHA, Release)"
BUILD_ARGS=(
  -project "$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -configuration Release
  -destination 'platform=macOS'
  CONFIGURATION_BUILD_DIR="$PWD/$BUILD_DIR"
  CODE_SIGN_STYLE=Manual
  # Stamped on the command line, not read from the project. UpdateChecker compares the release
  # tag against CFBundleShortVersionString, so an app that reports a version older than the
  # release it came from tells every user to upgrade to what they are already running.
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD"
  # On the command line rather than only in the project, because Swift package targets live in a
  # generated project of their own and do not inherit ARCHS from ours. Without this the Release
  # build goes universal and fails compiling FluidAudio for x86_64 — a machine this app cannot run
  # on anyway.
  ARCHS=arm64
)

if [ "$NOTARIZE" = true ]; then
  BUILD_ARGS+=(
    CODE_SIGN_IDENTITY="$IDENTITY"
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
else
  # The Release configuration names a Developer ID identity that does not exist here, so signing
  # is turned off for the build and done by hand below.
  BUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${BUILD_ARGS[@]}" build

echo "==> Signing bundle with hardened runtime"
# --options runtime is mandatory for notarization, and harmless without it.
SIGN_ARGS=(--force --deep --options runtime --entitlements "$APP_NAME.entitlements" --sign "$IDENTITY")
# A timestamp needs Apple's timestamp server and a real certificate; an ad-hoc signature cannot
# carry one, and asking for it fails the build.
[ "$NOTARIZE" = true ] && SIGN_ARGS=(--timestamp "${SIGN_ARGS[@]}")

codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Building disk image"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
# The symlink is what makes the window a drag-to-install target rather than a puzzle.
ln -s /Applications "$STAGING/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

if [ "$NOTARIZE" = true ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"

  echo "==> Notarizing (this waits for Apple, typically 1-5 minutes)"
  xcrun notarytool submit "$DMG" \
    --apple-id "$NOTARY_APPLE_ID" \
    --password "$NOTARY_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

  echo "==> Stapling"
  # Stapling attaches the notarization ticket to the file, so it opens cleanly even offline.
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  echo
  echo "✓ $DMG is signed, notarized and stapled."
  spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
  write_checksums
else
  # The one thing a person upgrading needs told, and it differs by path — which is the whole
  # reason the two are worth distinguishing on the release page.
  if [ "$IDENTITY" != "-" ]; then
    # A quoted heredoc, not a double-quoted string: the note contains backticks, and inside double
    # quotes those are command substitution.
    UPGRADE_NOTE="$(cat <<'NOTE'
This build is signed with a stable certificate, so macOS keeps the Accessibility grant across
updates. Coming from a release older than that change you lose it once, because the entry System
Settings is showing was granted to a differently signed app: it still displays a ticked
OurWhisper, and it no longer applies. Remove OurWhisper from the list with the **-** button and
add this build back, or run

```bash
tccutil reset Accessibility com.grozoww.ourwhisper
```

and grant it again. That is the last time you have to.
NOTE
)"
  else
    UPGRADE_NOTE="$(cat <<'NOTE'
Because this build is ad-hoc signed, its signature changes with every release. macOS treats that
as a different app and drops the Accessibility grant, so after an update you have to re-tick
OurWhisper in System Settings > Privacy & Security > Accessibility.
NOTE
)"
  fi

  # Written to a file rather than printed, so the release workflow can paste it into the release
  # notes verbatim. Someone who downloads an app that refuses to open and is given no explanation
  # concludes it is broken.
  cat > "$DIST_DIR/INSTALL.md" <<INSTALL
## Installing

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/grozoww/our-whisper/main/scripts/install.sh | bash
\`\`\`

That downloads this DMG, copies OurWhisper to Applications, and clears the download quarantine
flag. The last step is the one that matters: this build is **not notarized**, and macOS refuses to
open an unnotarized download at all — the dialog claims the app is damaged, which is untrue.
Notarization needs a paid Apple Developer account.

### By hand instead

1. Open the DMG and drag **OurWhisper** to Applications.
2. **Right-click OurWhisper in Applications and choose Open**, then confirm.

If macOS still refuses, clear the flag yourself:

\`\`\`bash
xattr -dr com.apple.quarantine /Applications/OurWhisper.app
\`\`\`

### First run

OurWhisper asks for **Microphone** and **Accessibility** permission. Both are required: the
microphone to hear you, Accessibility to watch for the hotkey and paste into the focused field.
It is a menu bar app — look for the microphone icon in the menu bar, not the Dock.

$UPGRADE_NOTE
INSTALL

  echo
  if [ "$IDENTITY" != "-" ]; then
    echo "✓ $DMG is built and signed with '$IDENTITY'."
    echo "  Not notarized, so Gatekeeper will warn on first open, but the Accessibility grant"
    echo "  survives updates. Designated requirement:"
    codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /    /p'
  else
    echo "✓ $DMG is built and ad-hoc signed."
    echo "  Not notarized, and users lose Accessibility on every update."
  fi
  echo "  Ship $DIST_DIR/INSTALL.md alongside it, or paste it into the release notes."
  write_checksums
fi

ls -lh "$DIST_DIR"
