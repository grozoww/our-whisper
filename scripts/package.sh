#!/usr/bin/env bash
#
# Builds the release OurWhisper.dmg: signed with a Developer ID, notarized by Apple, stapled.
#
#   ./scripts/package.sh                 what a release is
#   ./scripts/package.sh --no-notarize   signed only, to try the signing without waiting on Apple
#
# There is no ad-hoc or self-signed variant, and that is deliberate. Those existed while this
# project had no Apple account, and each was a way for a release to go out looking finished and be
# wrong: ad-hoc pins the Accessibility grant to one exact binary, so every update silently broke
# dictation; self-signed cannot be notarized, so every download needed a quarantine workaround. A
# build that cannot be signed and notarized now stops here instead. For a build to run on your own
# Mac, use ./scripts/run.sh.
#
# Runs in CI (see .github/workflows/release.yml) and locally, so a release can be reproduced and
# debugged on a laptop.
#
# Environment:
#   SIGNING_IDENTITY         the certificate, by name: "Developer ID Application: Name (TEAMID)".
#                            Left unset, the one in your keychain is used.
#   NOTARY_KEYCHAIN_PROFILE  a profile made by `xcrun notarytool store-credentials` — what a laptop
#                            uses. CONTRIBUTING.md has the one command that makes it.
#   NOTARY_KEY_PATH          the App Store Connect API key, a .p8 file   ┐
#   NOTARY_KEY_ID            its Key ID                                  ├ all three, for CI
#   NOTARY_ISSUER            the Issuer ID of the team that made it      ┘

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OurWhisper"
BUILD_DIR="build/release"
DIST_DIR="dist"
APP="$BUILD_DIR/$APP_NAME.app"

NOTARIZE=true
case "${1:-}" in
  "") ;;
  --no-notarize) NOTARIZE=false ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

# VERSION, BUILD, SHA and RELEASE_NAME. Derived rather than read out of the project, so the DMG
# filename, the version inside the app and the name on the release page cannot drift apart. See
# scripts/version.sh for how the number is arrived at.
eval "$(./scripts/version.sh)"

fail() {
  echo "✗ $*" >&2
  exit 1
}

# MARK: - Credentials, checked before anything is built

# `-v`: only identities macOS considers valid. A Developer ID whose private key is missing, or
# whose certificate has expired, is listed without it and fails at the first `codesign` instead.
IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || fail "No Developer ID Application certificate. Create one in Xcode (Settings > Accounts > Manage Certificates), or set SIGNING_IDENTITY."

NOTARY_ARGS=()
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
  [ -f "$NOTARY_KEY_PATH" ] || fail "NOTARY_KEY_PATH points at $NOTARY_KEY_PATH, which is not a file."
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
fi
if [ "$NOTARIZE" = true ] && [ ${#NOTARY_ARGS[@]} -eq 0 ]; then
  fail "No notarization login. Set NOTARY_KEYCHAIN_PROFILE, or NOTARY_KEY_PATH with NOTARY_KEY_ID and NOTARY_ISSUER. (--no-notarize signs without it.)"
fi

if [ "$NOTARIZE" = true ]; then
  DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
else
  DMG="$DIST_DIR/$APP_NAME-$VERSION-unnotarized.dmg"
  echo "==> Not notarizing. This disk image is for trying the signing, not for release."
fi

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# MARK: - Build

echo "==> Building $APP_NAME $VERSION (build $BUILD, $SHA, Release)"
BUILD_ARGS=(
  -project "$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -configuration Release
  -destination 'platform=macOS'
  CONFIGURATION_BUILD_DIR="$PWD/$BUILD_DIR"
  CODE_SIGN_STYLE=Manual
  # Xcode signs nothing here. The bundle is signed by hand below, inside out, once — so there is
  # one signing operation to reason about instead of Xcode's and then another over the top.
  CODE_SIGNING_ALLOWED=NO
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
xcodebuild "${BUILD_ARGS[@]}" build

# MARK: - Sign

# Inside out: a signature covers what is inside the thing it signs, so the framework goes first and
# the app last, one at a time and never `--deep` (which would hand the framework the app's
# entitlements). The hardened runtime and a secure timestamp are what notarization requires.
#
# The hardened runtime is also why only a Developer ID works. dyld then refuses any library that
# was not signed by Apple or by the same *team* as the app, and a self-signed or ad-hoc signature
# has no team: llama.framework, signed with the very same key in the very same step, is refused as
# "different Team IDs" and the app dies at launch. Measured on this app's real build.
#
# Only frameworks are signed here because they are the only nested code there is. Another kind
# (an XPC service, a helper) fails `--verify --strict` below and notarization, loudly, and is
# added here then.
echo "==> Signing with '$IDENTITY'"
SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
for framework in "$APP"/Contents/Frameworks/*.framework; do
  [ -e "$framework" ] && "${SIGN[@]}" "$framework"
done
"${SIGN[@]}" --entitlements "$APP_NAME.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# The one thing `--verify` cannot see: dyld refusing a library at launch is a crash before `main`
# on a signature that is perfectly valid. An empty HOME so it reads nothing of anyone's, and it
# quits as soon as it is up — see `SelfTest.onlyChecksItLaunches`.
echo "==> Launching the signed app once"
LAUNCH_HOME="$(mktemp -d)"
LAUNCHED="$(HOME="$LAUNCH_HOME" OURWHISPER_SELFTEST_LAUNCH=1 perl -e 'alarm 60; exec @ARGV' \
  "$APP/Contents/MacOS/$APP_NAME" 2>&1)" || { echo "$LAUNCHED" | head -12 >&2; fail "The signed app does not launch."; }
rm -rf "$LAUNCH_HOME"
[[ "$LAUNCHED" == *"OurWhisper launched"* ]] || { echo "$LAUNCHED" | head -12 >&2; fail "The signed app did not report that it launched."; }
echo "    It launches."

# MARK: - Disk image

echo "==> Building disk image"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
# The symlink is what makes the window a drag-to-install target rather than a puzzle.
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZE" = true ]; then
  echo "==> Notarizing (this waits for Apple, usually a few minutes)"
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait --timeout 30m

  # Stapling is the check that Apple said yes, and it fails closed: a build Apple rejected has no
  # ticket to attach. Its own output is not much help then, so the way to the real reason is here.
  echo "==> Stapling"
  xcrun stapler staple "$DMG" \
    || fail "Stapling failed — most likely Apple rejected the build. The submission id is in the output above: xcrun notarytool log <id> ${NOTARY_ARGS[*]}"
  xcrun stapler validate "$DMG"

  # Gatekeeper's own verdict on the file people will download, not ours.
  spctl --assess --type open --context context:primary-signature -vv "$DMG" \
    || fail "Gatekeeper does not accept $DMG after notarization and stapling."

  # Written to a file so the release workflow can paste it into the release notes.
  cat > "$DIST_DIR/INSTALL.md" <<'INSTALL'
## Installing

Open the disk image, drag **OurWhisper** to Applications, and open it. It is signed with an Apple
Developer ID and notarized by Apple, so macOS opens it without a warning. Already running
OurWhisper? It offers each new release itself, and installs it when you say so.

Prefer a terminal? This does the same thing:

```bash
curl -fsSL https://raw.githubusercontent.com/grozoww/our-whisper/main/scripts/install.sh | bash
```

On first launch OurWhisper asks for **Microphone** and **Accessibility** permission, and downloads
its two models: the speech model (600 MB) and the cleanup model (2.8 GB). Both run on your Mac and
nothing you say leaves it. The Home screen shows how far each one is.

### Coming from a release signed with a self-signed certificate

Earlier releases were signed with a certificate we made ourselves, and macOS treats a build signed
by Apple's Developer ID as a different app. Download this one by hand — those releases cannot
install it from inside the app — and **allow Accessibility and the microphone once more**. If
Accessibility still looks ticked and does nothing, run

```bash
tccutil reset Accessibility com.grozoww.ourwhisper
```

and grant it again. From here on, updates keep every permission.
INSTALL
  echo
  echo "✓ $DMG is signed, notarized and stapled."
else
  echo
  echo "✓ $DMG is signed with '$IDENTITY', and not notarized."
  codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /  designated requirement: /p'
fi

# scripts/install.sh checks the download against this. It is served from the same host as the
# DMG, so it proves nothing about the publisher — it catches a truncated or corrupted download,
# which over a 100 MB file on a bad connection is the failure people actually hit.
# `./*.dmg` guards against a filename that starts with a dash; the sed drops the prefix again so
# the file reads the way a SHA256SUMS is expected to.
(cd "$DIST_DIR" && shasum -a 256 ./*.dmg | sed 's| \./| |' > SHA256SUMS)

ls -lh "$DIST_DIR"
