# Contributing to OurWhisper

## Get building

```bash
git clone https://github.com/<you>/our-whisper.git
cd our-whisper
./scripts/dev-cert.sh     # one time — read "The signing trap" below first
./scripts/run.sh          # build and launch
```

Requires Xcode 27+ (for the toolchain, not necessarily the editor), which itself needs macOS
26.6+, and Apple Silicon. The app it builds runs on macOS 15+.
Swift package dependencies resolve on the first build.

It is a menu bar app. After launching, look for the microphone icon in the menu bar — there is
no Dock icon and nothing appears in command-tab.

## Read this first: the signing trap

OurWhisper needs macOS **Accessibility** permission to paste text into other apps and to watch for
the global hotkey. macOS ties that permission to the app's **code signature**.

Xcode's default "Sign to Run Locally" produces an *ad-hoc* signature that is different on every
single build. So macOS sees each build as a brand new app that has never been granted anything.
The symptom is nasty because it is silent: you grant Accessibility, it works, you change one line,
rebuild, and dictation stops. No error, no prompt, nothing in the log.

`./scripts/dev-cert.sh` fixes this by creating a self-signed certificate called `OurWhisper Dev`
in your login keychain, so the signature stays the same across rebuilds. It needs no sudo and asks
for no password. The certificate never leaves your machine and is not used for distribution.

It prints `CSSMERR_TP_NOT_TRUSTED` next to the identity. **That is expected.** The certificate is
deliberately not installed as a trusted root — `codesign` does not require that in order to sign
with it, and leaving it untrusted is what keeps the script prompt-free and your trust store clean.

You can see the difference the certificate makes. `codesign -d -r-` prints the *designated
requirement*, which is what macOS actually stores the permission against:

```
ad-hoc      designated => cdhash H"e7c60c73…"
certificate designated => identifier "com.grozoww.ourwhisper" and certificate leaf = H"5792c7a4…"
```

The first names one exact binary. The second names the bundle id and the certificate, so anything
signed by the same certificate satisfies it. That is the whole mechanism. Releases do the same
with a Developer ID, whose requirement names the Apple team instead of one certificate — see
"Shipping a build".

### The other half of the trap: two copies

Accessibility is granted to one app **bundle at one path**. A second clone, or a git worktree,
builds a second `OurWhisper.app` into a different DerivedData directory — and a permission granted
to the first does not apply to the second, while System Settings still shows a ticked OurWhisper.
The symptom is "I granted it and the app still says I have not".

The Home screen names the bundle it is actually running from and warns when other builds exist.
Remove every OurWhisper from the Accessibility list, then add back exactly that one.

If dictation stops working after a rebuild anyway:

1. System Settings → Privacy & Security → Accessibility — remove OurWhisper, then add it back
2. Check the identity still exists: `security find-identity -p codesigning | grep OurWhisper`
   (note: no `-v`, which would filter out this deliberately-untrusted certificate)
3. Check you granted the copy you are running — the path is on the Home screen

The app also ships a permission health check: if the event tap fails to arm, it says which
permission is missing rather than failing quietly.

## Day-to-day commands

```bash
./scripts/run.sh                          # build and relaunch
./scripts/run.sh --build                  # build only
./scripts/run.sh --test                   # unit tests
./scripts/run.sh --check                  # everything CI runs, before you push
./scripts/run.sh --logs                   # stream the app's logs
./scripts/run.sh --selftest speech.wav ru # transcribe a file, no UI or permissions needed
./scripts/audit-deps.sh                   # dependency pinning and vulnerability check
./scripts/screenshots.sh                  # redraw the README's screenshots

OURWHISPER_SECTION=modes open -a OurWhisper   # open the window straight onto a screen
```

`--logs` passes `--level info` deliberately: most of the useful output — transcripts, timings,
model loading — is logged at info level, which `log show` hides by default.

`--selftest` exists because the interactive path cannot run without Accessibility permission.
It answers the question that actually matters — does the model transcribe on this machine — with
one command, and works on a fresh clone and in CI.

`--check` runs the same three gates as CI: a warning-free build, the tests, and the dependency
audit. Running it before pushing turns a red pull request into a local failure.

## Tests

Swift Testing, in `Tests/`. They need no API key, no network, no microphone and no permissions —
which is what lets them run on a fork's CI and on a machine that has granted this app nothing.

Three things worth knowing before adding one:

**Cloud providers use `StubHTTPClient`.** Every provider takes an `HTTPClient`, so the network is a
parameter rather than a global. Responses are recorded shapes, and the requests are captured so a
test can assert on what *would* have been sent — that is how `sendsNothingIdentifying` keeps the
no-telemetry promise honest.

**Stores take a `directory:`.** Always pass one, using `TemporaryDirectory` from
`Tests/TestSupport.swift`. A store left on its default writes to the real Application Support
directory and destroys the settings, modes, vocabulary and history of whoever runs the suite.

**Screens are rendered, not just compiled.** `ViewRenderingTests` builds every sidebar destination
against real stores and forces a layout pass. A SwiftUI view that crashes on construction — a
mismatched `Picker` selection type, an index out of range — compiles perfectly and fails the first
time someone clicks that row. Add new screens to that test.

The event tap, the paste path, CoreAudio device selection and the second half of `UpdateInstaller`
are not covered: they need permissions, real hardware, or a signed build installed over another
signed build. That is why the pull request checklist below asks which apps you tested pasting into,
and what you installed over what.

## Dependencies

Every dependency is pinned to an **exact** version, and `Package.resolved` is committed. A version
range means CI and your machine can resolve different code from the same commit, and that a
compromised release inside the range lands without review.

`./scripts/audit-deps.sh` enforces that, checks the resolved file has not drifted, and queries
[osv.dev](https://osv.dev) — which carries the GitHub Advisory Database — for known vulnerabilities
in what is pinned. CI runs it on every pull request and again weekly, because an advisory can be
published for code that has not changed. Dependabot opens the update pull requests; nothing updates
itself.

Two traps, both found the hard way:

**A package with a build-tool plugin will not build from the command line** until Xcode trusts the
plugin. `mlx-swift` 0.31.5 added a CUDA build plugin and the build fails with
`Validate plug-in "CudaBuild"`. Prefer a version without the plugin over disabling plugin
validation, which would auto-trust arbitrary build-time code.

**`mlx-swift` 0.31.5+ also needs Xcode 26's separately-downloaded Metal toolchain**
(`xcodebuild -downloadComponent MetalToolchain`, several gigabytes). This is why cleanup runs
Gemma 4 through llama.cpp, whose package ships a prebuilt framework pinned by checksum, rather
than through MLX: same privacy guarantee, no multi-gigabyte tax on every contributor and every CI
run.

## Editor

**Xcode** is needed only for SwiftUI previews and its own debugger. Open `OurWhisper.xcodeproj`.

**VS Code / Cursor** works for everything else. Install the
[Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode)
and [LLDB DAP](https://marketplace.visualstudio.com/items?itemName=llvm-vs-code-extensions.lldb-dap),
then generate the build-server config that gives sourcekit-lsp its compiler flags:

```bash
brew install xcode-build-server
xcode-build-server config -project OurWhisper.xcodeproj -scheme OurWhisper
```

`buildServer.json` holds absolute paths for your machine, so it is git-ignored — regenerate it
after a fresh clone. It points at Xcode's default DerivedData, which is why `scripts/run.sh`
builds there too rather than into a local directory; a custom `-derivedDataPath` would leave the
editor indexing a directory nothing writes to.

`.vscode/` ships Build, Test, Check, Build and Run, Stream logs and Self-test tasks (⇧⌘B), plus
two debug configurations. The self-test one is the useful one before Accessibility is granted.

## Rules

**Never commit a secret.** Every API key is supplied by the user at runtime and stored in the
macOS Keychain. Nothing in the build, the tests, or CI may require a key. Tests for cloud
providers use recorded fixtures.

**The app must work with zero keys.** The local model and local cleanup are the default path. A
key is always optional.

**No telemetry, ever.** No analytics, no crash reporting, no phone-home beyond the user-initiated
update check. This is the point of the project.

**Do not add a second local speech model without evidence.** The choice of Parakeet over Whisper
is documented in the README with benchmark numbers. If you want to change it, bring numbers.

**Keep the build warning-free.** Swift 6 concurrency warnings in the audio path are not noise —
that code runs on the audio thread, where "probably fine" becomes a dropout.

## Shipping a build

Releases are built by CI: merging to `main` publishes one, and the app's own updater offers it to
everyone running an older copy. `./scripts/package.sh` is the same build on your laptop, for
reproducing a problem.

```bash
./scripts/package.sh                  # signed with your Developer ID, notarized, stapled
./scripts/package.sh --no-notarize    # signed only, to try the signing without waiting on Apple
```

There is no unsigned or self-signed release, and CI refuses to make one: a missing secret fails
the job rather than shipping whatever can be built. Both existed while this project had no Apple
account, and both were ways for a release to look finished and be wrong. An ad-hoc signature pins
the Accessibility grant to one exact binary, so every update silently broke dictation; a
self-signed one cannot be notarized, so every download needed a workaround. For a build to run on
your own Mac, use `./scripts/run.sh`.

**Why it has to be a Developer ID, not only notarized.** The app embeds `llama.framework`, and the
hardened runtime — which notarization requires — makes dyld refuse any library that was not signed
by the same *team* as the app. A self-signed or ad-hoc signature has no team, so the app crashes at
launch with "different Team IDs", even when the framework was signed with the very same key.
`package.sh` signs the framework first and the app last, never with `--deep`, and then launches
the result once, because that crash is the one thing `codesign --verify` cannot see.

**Secrets.** The release workflow reads five repository secrets:

| Secret | What it is |
| --- | --- |
| `CSC_LINK` | the Developer ID Application certificate with its private key, exported from Keychain Access as a `.p12`: `base64 -i cert.p12 \| pbcopy` |
| `CSC_KEY_PASSWORD` | the password you gave that `.p12` |
| `APPLE_API_KEY` | the *contents* of the App Store Connect API key, the `.p8` file |
| `APPLE_API_KEY_ID` | that key's Key ID |
| `APPLE_API_ISSUER` | the Issuer ID of the team, from the same page |

To run `package.sh` yourself, put the same key in your keychain once. `package.sh` then finds the
certificate on its own:

```bash
xcrun notarytool store-credentials OurWhisper --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>
NOTARY_KEYCHAIN_PROFILE=OurWhisper ./scripts/package.sh
```

**Trying it before you merge.** Actions → Release → Run workflow, on your branch. It signs,
notarizes and publishes a *prerelease*, which the app's update check does not offer. This is the
only way to prove the secrets and the runner's keychain work together, and it costs nothing to
repeat.

**Certificates expire.** A Developer ID certificate issued from Apple's older intermediate is
capped at that intermediate's expiry, 1 Feb 2027, rather than the usual five years; one from the
G2 profile runs to about 2031. Signatures made while it was valid stay valid, because they are
timestamped, and the requirement the app is installed with names the Apple *team*, not the
certificate — so a renewed one keeps updates and permissions working. Renewing is a new `.p12` and
new `CSC_LINK` and `CSC_KEY_PASSWORD`; there is no code to change.

### Version numbers

Nobody types the patch number. `scripts/version.sh` works out what a build is called, and both
`package.sh` and the release workflow ask it rather than deciding for themselves — so the DMG
filename, the version baked into the app and the name on the release page cannot drift apart.

The `VERSION` file at the repository root holds the line you are on. **Major and minor are yours**:
edit the file when a release deserves the number. **The patch is counted**: it is the number of
pull requests merged since `VERSION` last changed.

```
VERSION says 1.0.0, nothing merged since   →  1.0.0
four PRs merged since                      →  1.0.4
edit VERSION to 1.1.0                      →  1.1.0, counting starts again
```

PRs are counted along main's first-parent chain, so only what landed counts, once each, and both
merge styles are recognised — `Merge pull request #12` and a squashed `Some change (#12)`. A commit
pushed straight to main is not a PR and does not move the number.

A `v*` tag on the exact commit being built overrides all of it. Tagging `v1.2.0` is a decision, and
a release whose tag and whose app disagree tells every user to upgrade to what they are already
running — `UpdateChecker` compares the release tag against `CFBundleShortVersionString`.

`MARKETING_VERSION` in the project is kept equal to the `VERSION` file so a plain Xcode build is
not wrong, but it is not what a release uses; `package.sh` passes the computed value on the
`xcodebuild` command line. `CURRENT_PROJECT_VERSION` gets every PR ever merged, plus one — a
build number has to keep rising when the marketing version resets.

```bash
./scripts/version.sh            # VERSION=… BUILD=… SHA=… RELEASE_NAME=…
./scripts/version.sh --name     # release-1.0.3-a1b2c3d
```

This needs real history. `actions/checkout` clones a single commit by default, which has no merges
in it to count, so both workflows pass `fetch-depth: 0`.

### Where builds come from

Releases are named `release-<version>-<short sha>` — `release-1.0.3-a1b2c3d` — whatever the
trigger. The tag says what kind of build it is; the name says which code is in it, which is the
first thing anyone asks when a download misbehaves.

| Trigger | Tag | Name |
| --- | --- | --- |
| Pull request | — | Nothing published. Builds and tests only — no packaging. |
| Push to `main` | `release-1.0.3-a1b2c3d` | `release-1.0.3-a1b2c3d` |
| Push a tag `v*` | the tag | `release-1.0.3-a1b2c3d` |
| Actions → Run workflow | `build-<n>`, a prerelease, for rehearsing | `release-1.0.3-a1b2c3d (build 7)` |

Every one of them is signed and notarized, or the job fails — `.github/workflows/release.yml`
checks the five secrets are present before it builds anything.

A `v*` tag is a finished release, and so is a merge to `main`; only a `workflow_dispatch` rehearsal
is a prerelease, because that is a build nobody merged. This was once decided by whether the build
was notarized, and with no Apple account that marked *every* release a prerelease. `/releases/latest`
skips prereleases, so the app's update check got a 404 and quietly reported "up to date" for ever.

Nothing is deleted and no tag is ever reused, so pushing to `main` adds a build rather than
replacing the one before it. Each tag carries the version and the commit, so it is unique per
commit and exactly one DMG is ever attached to it.

The DMG job in `ci.yml` exists because the Release build is not the Debug build: it signs, it
hardens the runtime, it compiles the asset catalog and it is arm64-only. Each of those has broken
without the Debug build noticing.

### Installing

`scripts/install.sh` is the `curl | bash` in the README. It asks `/releases/latest`, and if that
404s — which it does when every release is a prerelease — it reads the list and takes the highest
version out of the DMG filenames. Not the first entry: GitHub does not return that list newest
first, and reading it positionally is what had `curl | bash` installing 1.0.8 while 1.0.10 was out.

It then asks Gatekeeper about the disk image *before* it quits or touches the installed copy,
and stops if the answer is no — a release that is not notarized, or that was tampered with, is not
worth replacing a working app for. It does not remove the quarantine flag: on a notarized app that
only switches the check off. Last, it compares the installed copy's signing requirement with the new
one and clears the Accessibility grant when they differ, because a grant for a different signature
is a ticked box that applies to nothing.
