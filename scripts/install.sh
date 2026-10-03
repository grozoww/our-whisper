#!/usr/bin/env bash
#
# Installs OurWhisper from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/grozoww/our-whisper/main/scripts/install.sh | bash
#
# Options, when running the script from a checkout rather than a pipe:
#
#   --version v0.2.0   install a particular release instead of the newest one
#   --prefix DIR       install somewhere other than /Applications
#   --no-open          install but do not launch
#
# Why this exists rather than "download the DMG and drag it across": it does the same thing in
# one line, checks what it downloaded before it replaces anything, and clears a dead Accessibility
# grant, which is the one step people used to have to be talked through. Releases are signed with
# an Apple Developer ID and notarized, so the DMG also opens with a double-click; this is for people
# who would rather paste a line.
#
# It does not remove the download quarantine flag, and no longer needs to. On a notarized app that
# step only switches Gatekeeper off, and a download that macOS would refuse is exactly the one it
# should refuse — so the script asks Gatekeeper itself, before installing, and stops if it says no.

set -euo pipefail

REPO="grozoww/our-whisper"
APP_NAME="OurWhisper"
PREFIX="/Applications"
VERSION=""
OPEN_AFTER=true

# Written out rather than read back out of "$0": piped to bash, "$0" is "bash", and printing the
# usage would fail with a confusing error about a missing file.
usage() {
  cat <<'USAGE'
Installs OurWhisper from the latest GitHub release.

  curl -fsSL https://raw.githubusercontent.com/grozoww/our-whisper/main/scripts/install.sh | bash

Options (pass them after `bash -s --` when piping):

  --version v0.2.0   install a particular release instead of the newest one
  --prefix DIR       install somewhere other than /Applications
  --no-open          install but do not launch

Releases are signed with an Apple Developer ID and notarized. The script checks that with
Gatekeeper before it installs anything, and stops if the release does not pass.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a tag, e.g. v0.2.0}"; shift 2 ;;
    --prefix)  PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --no-open) OPEN_AFTER=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

# MARK: - Preflight
#
# Checked before anything is downloaded, so a machine that cannot run the app is told why instead
# of spending two minutes fetching 100 MB it will not be able to open.

[ "$(uname -s)" = "Darwin" ] || die "OurWhisper is a macOS app."

[ "$(uname -m)" = "arm64" ] || die "OurWhisper needs Apple Silicon. Speech runs on the Neural Engine, which Intel Macs do not have."

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 15 ] || die "OurWhisper needs macOS 15 or later. This Mac is on $(sw_vers -productVersion)."

command -v curl >/dev/null 2>&1 || die "curl is required."

# MARK: - Find the download
#
# Asked two ways, because neither alone is reliable.
#
# /releases/latest is the right question, and GitHub answers it correctly: not a draft, not a
# prerelease, most recently published. It 404s when *every* release is a prerelease, which was the
# state this project was in for its whole life and what made the app's update check go quiet. Only
# a workflow_dispatch rehearsal is a prerelease now, so this is the ordinary path again.
#
# The list is the fallback, and the order GitHub returns it in must not be trusted. That order is
# not newest-first and does not match id, created_at or published_at — asked today it puts v1.0.8
# ahead of 1.0.9, 1.0.10 and 1.0.7. Taking the first DMG in the response is what installed 1.0.8
# over 1.0.10 for anyone who ran this script. So the version is read out of each DMG's own
# filename and the highest one wins, which relies on nothing GitHub promises.
#
# Parsed with grep and sed rather than jq, because jq is not on a stock Mac and this script has to
# run on one.

# `|| true` on the pipelines below: finding nothing is a normal outcome that the caller reports
# properly. Without it, `set -e` and `pipefail` between them kill the script on an empty grep and
# the user is left with a bare exit code and no idea why.
dmg_urls() {
  printf '%s' "$1" \
    | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.dmg"' \
    | sed 's/.*"\(https[^"]*\)"$/\1/' || true
}

# Highest version, not first in the response. `-n` with `p` drops any DMG whose name carries no
# version rather than letting it sort to the top, and `sort -V` is what puts 1.0.10 above 1.0.9.
#
# The suffix after the version is optional. A notarized build is `OurWhisper-1.1.0.dmg` and the
# others are `-unnotarized` or `-unsigned`; a pattern that demanded the dash and the word dropped
# every notarized release, and with them the only DMG there was.
newest_dmg() {
  dmg_urls "$1" \
    | sed -n 's|.*/[^/]*-\([0-9][0-9.]*\)\(-[^/]*\)\{0,1\}\.dmg$|\1	&|p' \
    | sort -t'	' -k1,1V \
    | tail -1 \
    | cut -f2- || true
}

step "Looking up the latest release"

if [ -n "$VERSION" ]; then
  RELEASE="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$REPO/releases/tags/$VERSION")" \
    || die "No release tagged $VERSION in $REPO. See https://github.com/$REPO/releases"
  # One release, so there is nothing to choose between.
  DMG_URL="$(dmg_urls "$RELEASE" | head -1 || true)"
else
  # No -S here, unlike everywhere else: a 404 from this one is the expected fallback, not a fault,
  # and letting curl print "error: 404" before the script quietly recovers reads like a failure.
  RELEASE="$(curl -fsL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$REPO/releases/latest" || true)"
  DMG_URL="$(newest_dmg "$RELEASE")"

  if [ -z "$DMG_URL" ]; then
    RELEASE="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$REPO/releases?per_page=100")" \
      || die "Could not reach the GitHub releases API. Check your connection, or download the DMG by hand from https://github.com/$REPO/releases"
    DMG_URL="$(newest_dmg "$RELEASE")"
  fi
fi

[ -n "$DMG_URL" ] || die "No DMG found in the releases for $REPO${VERSION:+ at $VERSION}. See https://github.com/$REPO/releases"

# Taken from the DMG's own release directory rather than searched for separately. A second search
# over the list can return the SHA256SUMS of a *different* release, and then the filename lookup
# below matches nothing and the download goes unverified without ever saying so. Older releases
# predate the file, so its absence is still not an error.
SUMS_URL="${DMG_URL%/*}/SHA256SUMS"

DMG_FILE="$(basename "$DMG_URL")"

# MARK: - Download

WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

step "Downloading $DMG_FILE"
curl -fL --progress-bar "$DMG_URL" -o "$WORK/$DMG_FILE" || die "Download failed."

step "Checking the download"
# Verified against a file from the same server, so this is not a signature — it catches a
# truncated or corrupted download, which is the failure that actually happens on a 100 MB file.
# Skipping is said out loud both ways round: a check that quietly does nothing reads exactly like
# one that passed.
if curl -fsSL "$SUMS_URL" -o "$WORK/SHA256SUMS"; then
  EXPECTED="$(grep -F "$DMG_FILE" "$WORK/SHA256SUMS" | awk '{print $1}' | head -1 || true)"
  ACTUAL="$(shasum -a 256 "$WORK/$DMG_FILE" | awk '{print $1}')"
  if [ -z "$EXPECTED" ]; then
    echo "    SHA256SUMS has no entry for $DMG_FILE — not checked."
  elif [ "$EXPECTED" != "$ACTUAL" ]; then
    die "Checksum mismatch. Expected $EXPECTED, got $ACTUAL. The download is corrupt — try again."
  fi
else
  echo "    This release predates SHA256SUMS — not checked."
fi

# MARK: - Install

DEST="$PREFIX/$APP_NAME.app"

step "Mounting $DMG_FILE"
MOUNT="$(hdiutil attach "$WORK/$DMG_FILE" -nobrowse -readonly -mountrandom /tmp \
  | grep -o '/tmp/[^[:space:]]*$' | tail -1 || true)"
[ -n "$MOUNT" ] && [ -d "$MOUNT/$APP_NAME.app" ] || die "The disk image did not contain $APP_NAME.app."

# Asked of the disk image, and before anything is quit or replaced. Gatekeeper's verdict is the one
# that matters — it is what every user's Mac will give — and a release it refuses is either not
# notarized (the ones made before this project had an Apple account are not) or tampered with,
# and neither is worth interrupting a working dictation for. The image rather than the app inside
# it: the ticket is stapled to the image, so this answers without a network, and a notarized image
# is Apple vouching for what is in it.
step "Checking with Gatekeeper"
spctl --assess --type open --context context:primary-signature "$WORK/$DMG_FILE" 2>/dev/null \
  || die "macOS would refuse this release: it is not signed and notarized by Apple. Nothing was installed. If it is the newest release, a newer one may be on its way — try again in a few minutes."

mkdir -p "$PREFIX" 2>/dev/null || true
[ -w "$PREFIX" ] || die "$PREFIX is not writable by this account. Re-run with --prefix \"\$HOME/Applications\"."

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  step "Quitting the running copy"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.5
  done
  pgrep -x "$APP_NAME" >/dev/null 2>&1 && die "$APP_NAME is still running. Quit it from the menu bar and run this again."
fi

# MARK: - Accessibility
#
# Read before the old bundle is deleted, because it cannot be read afterwards. macOS records the
# Accessibility grant against the *designated requirement* of the signature that was installed
# when the user granted it. If the incoming build has a different one, that grant is already dead
# — System Settings goes on showing a ticked OurWhisper that applies to nothing, which is the
# single most confusing way this app has ever failed. Comparing the two is what tells us whether
# it happened, and `-r-` writes to stderr, and comments the line out when the requirement is
# implicit, which is why both are handled here.
requirement_of() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p'
}

OLD_REQUIREMENT=""
[ -d "$DEST" ] && OLD_REQUIREMENT="$(requirement_of "$DEST" || true)"

# Replaced rather than merged. Copying over an existing bundle leaves files from the old version
# behind inside it, and a code signature covering files that are no longer supposed to be there
# fails to validate.
step "Installing to $DEST"
rm -rf "$DEST"
ditto "$MOUNT/$APP_NAME.app" "$DEST"

# Only when it actually changed. Resetting unconditionally would take a working permission away
# from everyone who reinstalls, which is a worse bug than the one this fixes.
NEW_REQUIREMENT="$(requirement_of "$DEST" || true)"
if [ -n "$OLD_REQUIREMENT" ] && [ "$OLD_REQUIREMENT" != "$NEW_REQUIREMENT" ]; then
  step "Clearing the Accessibility permission granted to the old build"
  echo "    Its signature changed, so macOS no longer applies that grant to this build."
  echo "    You will be asked for Accessibility once more, and this should be the last time."
  # No sudo: tccutil resets an app's own entry for the logged-in user. A failure here is not fatal
  # — the app's Home screen offers the same reset, and says how to do it by hand.
  tccutil reset Accessibility com.grozoww.ourwhisper >/dev/null 2>&1 || true
fi

hdiutil detach "$MOUNT" -quiet
MOUNT=""

echo
echo "✓ $APP_NAME is installed at $DEST"
echo
echo "  It is a menu bar app — no Dock icon, no window at startup. Look for the microphone"
echo "  glyph in the menu bar."
echo
echo "  On first run it asks for two permissions, and needs both:"
echo "    Microphone      to hear you"
echo "    Accessibility   to watch for the hotkey and paste into the focused field"
echo
echo "  Accessibility survives updates: releases are signed by the same Apple Developer ID team,"
echo "  which is what macOS ties the permission to. If dictation ever stops after an upgrade"
echo "  anyway, the Home screen has a 'Reset and ask again' button."
echo

if [ "$OPEN_AFTER" = true ]; then
  step "Opening $APP_NAME"
  open "$DEST"
fi
