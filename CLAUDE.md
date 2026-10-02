# CLAUDE.md

Working notes for agents and humans on this codebase. `README.md` is what the app is;
`CONTRIBUTING.md` is how to build it. This is what to know before changing it.

## What this app is

A macOS menu bar dictation tool. Hold a hotkey, talk, and the cleaned-up text is pasted into
whatever field had focus. Everything runs on the Mac by default: speech through NVIDIA Parakeet on
the Neural Engine, cleanup through rules plus Apple's on-device model.

Not sandboxed, on purpose — the Accessibility API cannot reach other apps from inside the App
Sandbox, and pasting into another app is the entire product. Distribution is Developer ID plus
notarization, never the Mac App Store.

## The four rules

These are from `CONTRIBUTING.md` and they are not negotiable. Everything below is downstream of
them.

1. **Never commit a secret.** Keys come from the user at runtime and live in the macOS Keychain.
   Nothing in the build, the tests or CI may require a key.
2. **The app works with zero keys.** Local speech and local cleanup are the default path.
3. **No telemetry, ever.** The only unattended network request is the GitHub release check, and it
   sends nothing about the user. Downloading an update is a second request, and it is only ever
   made on a button press — nothing about installing is wired to `checkAutomatically`, there is no
   pre-fetch and no retry timer. Both requests go out through `UpdateChecker.anonymousRequest`,
   which replaces the `User-Agent` and `Accept-Language` URLSession would otherwise fill in with
   the app version, the exact macOS build and the user's region. `sendsNothingIdentifying` and
   `sendsNothingIdentifyingWhenDownloading` are what keep that true, and both assert on the request
   the code sent rather than one the test built for itself — the first version of the second test
   passed with both wrappers deleted, which is no test at all.
4. **Keep the build warning-free.** CI fails on a warning. The Swift 6 concurrency warnings in the
   audio path are real defects; that code runs on the audio thread.

And one that follows from them:

5. **Audio never leaves the Mac implicitly.** Choosing a language Parakeet cannot handle does not
   quietly start uploading — it fails with a message naming the switch the user has to turn on.
   `TranscriptionRouter` is the only place that decision is made.

## Commands

```bash
./scripts/version.sh             # what this build is called, and why
./scripts/run.sh                 # build and relaunch
./scripts/run.sh --build         # build only
./scripts/run.sh --test          # unit tests
./scripts/run.sh --check         # what CI runs: warning-free build, tests, dependency audit
./scripts/run.sh --logs          # stream the app's logs at info level
./scripts/run.sh --selftest speech.wav ru   # transcribe a file, no UI or permissions needed
./scripts/audit-deps.sh          # dependency pinning and vulnerability check
./scripts/package.sh             # build a distributable DMG, signed so permission survives
./scripts/release-cert.sh        # once, ever: the certificate every release is signed with
./scripts/screenshots.sh         # redraw docs/images, the README's screenshots
./scripts/make-icon.swift        # redraw the app icon and menu bar glyph into Assets.xcassets

OURWHISPER_SECTION=modes open -a OurWhisper   # open the window on a given screen
OURWHISPER_SELFTEST_UPDATE=1 open /Applications/OurWhisper.app   # install the newest release over this copy
```

`--selftest` exists because the interactive path needs Accessibility permission, which a fresh
clone, a CI runner and an automated agent all lack. **If you are an agent and want to know whether
transcription works, this is the command** — not launching the app.

`OURWHISPER_SECTION` exists for the same reason on the UI side: the window is only reachable by
clicking a menu bar icon, which nothing automated can do. Values are the `NavigationSection` raw
values (`home`, `modes`, `vocabulary`, `configuration`, `sound`, `modelsLibrary`, `history`).

`screenshots.sh` is the third of these. It launches the app with `OURWHISPER_SCREENSHOT=<target>`,
which seeds demo data, poses one screen and prints its window number for `screencapture` — see
`ScreenshotMode`. **If you are an agent and want to see what a screen looks like**, this is the
command, and it is cheaper than the throwaway harness. `OURWHISPER_SCREENSHOT_SIZE=880x560` and
`OURWHISPER_SCREENSHOT_SIDEBAR=collapsed` pose the awkward cases — the window at its minimum, and
the screens whose own list becomes the leftmost thing in the window.

## Layout

```
Sources/
  App/          Entry point, AppState, menu bar
  Core/
    Audio/          Capture, device selection, WAV encoding
    DictationController.swift   The record → transcribe → clean → paste → remember loop
    History/        Transcripts and retention
    Hotkey/         CGEventTap and chord matching
    Injection/      Paste into the focused field
    Modes/          Per-context cleanup profiles
    Networking/     HTTPClient seam — the reason cloud code is testable
    Permissions/    Microphone and Accessibility
    Refinement/     Rule cleanup, on-device model, pipeline
    Security/       Keychain
    Settings/       Settings value, store, theme
    Sound/          Feedback sounds, CoreAudio device list
    Storage/        Paths, JSON file store, lenient decoding
    Transcription/  Provider protocol, Parakeet, Soniox, router
    Update/         Release check, and installing one over the running app
    Vocabulary/     Substitution list
  Resources/    Assets.xcassets — the app icon and menu bar glyph, drawn by scripts/make-icon.swift
  UI/           One directory per screen, plus DesignSystem
Tests/          Swift Testing, no network, no key, no permissions
```

The Xcode project uses **synchronized file groups**: a new file under `Sources/` or `Tests/` joins
its target automatically. Never edit `project.pbxproj` to add a file.

## Things that will catch you out

**Swift's `Codable` ignores property defaults.** A missing key throws — it does not fall back to
the default you wrote in the struct. Every persisted type therefore decodes through the helpers in
`Core/Storage/LenientDecoding.swift`. **If you add a field to `Settings`, `Mode`, `HistoryEntry` or
`VocabularyEntry`, add it to that type's `init(from:)` too.** Forgetting means every existing file
fails to decode, `JSONFileStore` quarantines it, and the user's settings, modes and history revert
on upgrade. `SchemaEvolutionTests` covers this.

**`\b` is ASCII-only.** It matches inside Cyrillic text, so any regex that needs a word boundary
must use the Unicode form in `RuleRefiner.RegexCache.wordRegex`. Russian and Ukrainian are two of
the app's primary languages; getting this wrong corrupts them silently.

**The event tap is fragile in two specific ways.** macOS disables it if a callback is slow, and it
dies silently when Accessibility is revoked. Both are handled in `HotkeyMonitor`; keep callbacks
fast and do not add work to them.

**Capture the paste target before drawing anything.** Showing the pill first lets
`frontmostApplication` change underneath, and the text lands in the wrong app.
`DictationController.beginRecording` gets this order right — do not reorder it.

**The clipboard has to be read before the paste, not after.** `TextInjector` pastes through the
clipboard, so by the time cleanup runs the user's clipboard is already the dictated text.
`DictationController.beginRecording` reads it alongside the paste target, for the same reason, and
it only reads it at all when the on-device model can run *and* some mode has "Use the clipboard as
context" or "Paste the clipboard where you ask for it" on — `RefinementPipeline.modelIsEnabled`
and `ModeStore.anyModeReadsClipboard` are those two conditions, and together they are what lets
the README say the clipboard is otherwise only touched to paste. `ClipboardContext` is the single
place that reads it, and it refuses anything marked `org.nspasteboard.ConcealedType`, which is
what a password manager sets on a copied password.

**The two clipboard toggles are opposite treatments of the same text.** Context shows it to the
on-device model, capped at `ClipboardContext.referenceLimit`, with a prompt forbidding the model
from repeating any of it. Paste never shows the model anything and reproduces the clipboard
verbatim at the marker — uncapped, because a copied stack trace the app quietly shortened would be
worse than not pasting it. Keep the capping on `ClipboardContext.reference`, not on the read: the
read result is what gets pasted. History records what was dictated, not the combined paste, so a
thirty-day history file never accumulates copies of the user's clipboard.

**Where the clipboard lands is the model's decision, and there is no rule behind it.** The
placeholder is *spoken*, so it never arrives as any phrase written down in advance: the recogniser
declines it, splits the compound, or the model rewords it. Every rule written to catch that either
missed the sentence or cut open a sentence that was only *about* the clipboard — "буфер обмена не
работает" is a complaint, not a request, and in Russian and Ukrainian the ordinary noun for
clipboard is already two words, so "more than one word" is not a test that separates them. A
user-editable phrase had the same fault with the user holding the blame. Both are gone.

What is left is the shape that works: the model is asked, in `OnDeviceRefiner.prompt`, to put
`ClipboardContext.marker` where the user asked for the clipboard — the judgement is the model's,
which is the part it is good at, and the output is a literal, which is the part a rule is good at.
Ask for a character offset instead and you get a number a small model guessed at, four out,
splitting a word.

**The clipboard is substituted for the marker last, and that ordering is the whole design.**
`ClipboardContext.substituted` runs after rules *and* after the model, because the one thing the
model must never see is the text it is about to reproduce — it rewords a stack trace, and
`OnDeviceRefiner.sanityChecked` then throws the answer away for growing past 1.6×. It is a plain
string replacement, so nothing in the clipboard is read as regex syntax.

**The *whether* is the model's too, and that reversed a rule this file used to state.** The request
used to go in the prompt only when `ClipboardContext.mentioned` found a clipboard noun in the
transcript, on the argument that the model should decide where and never whether — otherwise a
sentence that never mentioned the clipboard gets one dropped into the middle of it. That argument
stopped holding the moment a missing marker meant the clipboard was not pasted *at all*: a list of
nouns then decides, silently, that "paste what I copied" is not a request, and the user's clipboard
never arrives. A word list can only be wrong in that direction, in every language, and the shipped
list managed to reject the worked example in `ClipboardContext`'s own doc comment. The prompt
already tells the model to write nothing when the sentence was only *about* the clipboard, so the
veto lives there, once, where the judgement is. `shouldPlaceClipboard` is now only "does this mode
paste the clipboard, and is there one".

When no marker comes back — the model declined, timed out, or failed its sanity check —
**nothing is pasted**. There used to be a fallback that put the clipboard after the text in that
case, and it fired on every dictation the model was not asked or did not answer, so a mode with the
switch on stapled whatever was copied onto sentences that never mentioned it. The marker is the
only thing that knows where the clipboard goes; no answer beats the wrong place, and it is what
lets the switch stay on. A marker with no clipboard behind it is taken back out by
`removingMarker`, punctuation and all, rather than pasted as `[[CLIPBOARD]]` — including on the way
into History, which records the sentence rather than the token. What the user actually said is
still on the entry, in `rawText`.

**No model, no clipboard, and that includes not reading it.** Both clipboard toggles are downstream
of the model — one shows it what you copied, the other pastes it where the model marked — so
neither can do anything without it. `RefinementPipeline.modelIsEnabled` gates the *read* in
`beginRecording`, and `willUseModel` gates the paste, which also catches a mode with no
instructions (Raw is the shipped example). The alternative, appending the clipboard to every
sentence whenever the model was not there, is not the feature the toggle describes and made "the
clipboard sometimes ends up in my text" a thing that could happen. Both switches are disabled in
`ModesView` when the model is unavailable, so a switch is never on and quietly doing nothing.

There is no end-of-text fallback left anywhere, so `ClipboardContext.appended` is gone with it. A
timeout and a model that was never there now behave the same way — nothing is pasted — which is
one rule rather than two, and the one the toggle's own description promises.

**"Is there a text field here?" has three answers, and only one of them is worth a clipboard.**
A frontmost app with no caret swallows the synthetic ⌘V without a word, and the restore 220 ms
later puts the user's old clipboard back over the text — which is how a dictation into a Finder
window used to disappear behind a green tick and the word "Finder". Skipping that restore is the
fix, and it costs the user whatever they had copied, so it is spent only on a definite *no*.

`TextInjector.acceptance` is that decision, and it is pure so it can be tested. It used to be a
`Bool`, and every Accessibility call that *failed* came back as the same `false` as an empty
desktop — so a busy Chrome, an Electron app still building its accessibility tree, or an element
rebuilt during a five-second transcription all looked exactly like "there is nothing here", and
the app ate the clipboard while the paste visibly worked. `kAXErrorNoValue` is the app answering;
everything else is the app not answering, and not answering must restore. A role that came back is
evidence either way; a role that did not is not evidence at all.

The element is read at inject time, not at capture time, and the pid is checked against the
target. Reading it in `captureTarget` was wrong twice over: that runs inside the event tap
callback, where a round trip to another process is exactly what makes macOS switch the tap off,
and a handle taken before transcription is stale by the time it is asked — Chromium and Electron
rebuild their nodes constantly and a dead handle answers `kAXErrorInvalidUIElement` to everything.
The pid check exists because `activate()` is asynchronous: another app's text field is not
evidence about this one. But a foreign pid is not automatically a foreign app — macOS vends the
focused element from `com.apple.appkit.xpc.openAndSavePanelService` for an Open panel and from
`com.apple.WebKit.WebContent` for web content, and those have no app of their own. `belongs(owner:
to:ownerPolicy:)` tells them apart by activation policy: measured on macOS 26 those services are
`.prohibited` and `.accessory` while every real app is `.regular`. Treating a panel as "some other
app" demotes its real refusal to `.unknown`, and the restore then wipes out a dictation the panel
swallowed. A `false` must still never *stop* the ⌘V — browsers hand out one `AXWebArea` for a
whole page rather than an element per input, which is also why `AXWebArea` is in `textRoles`.

**The frontmost app is not always the app with the keyboard.** A non-activating window takes
keyboard focus without making its app frontmost — Warp's hotkey window is the one users hit — so
`NSWorkspace.frontmostApplication` goes on naming whatever was underneath, while Accessibility's
focused application names Warp. Every dictation into Warp used to be aimed, mode-matched and
recorded as the app below. `captureTarget` takes the workspace's answer, which is free, and asks
Accessibility on another thread; `confirmTarget` swaps the target when a *regular* app holds the
keyboard instead — regular for the same reason as `belongs`, since an Open panel answers from a
service with no app of its own.

Fixing the target alone does not fix the paste. Measured with two stand-in apps: ⌘V posted at
`.cgAnnotatedSessionEventTap` lands in the *frontmost* app, not in the window holding the
keyboard; posted to the target's pid it lands in the window. So the paste goes to the pid only when
the target is not frontmost, and every ordinary dictation keeps the tap it always used. And the
"user switched apps, re-activate the target" step must not fire here: Warp hides that window the
moment it loses focus. It asks Accessibility before activating anything.

**A transcript left on the clipboard is not something the user copied.** One `.clipboardOnly`
outcome used to be permanent: the dictated text stayed on the pasteboard, and every dictation
after it snapshotted that text as "the user's clipboard" and faithfully restored it, so a single
mis-detection turned into "my clipboard is always the last thing I dictated". `holdsOwnTranscript`
compares `NSPasteboard.changeCount` against the one the app produced when it wrote — a number, not
a copy of the text, because keeping the text would mean holding whatever was last dictated
(possibly a password read aloud) for the life of the process. When it is true the app neither
restores over it nor reads it back as clipboard context, and the moment the user copies anything
the answer goes back to false on its own.

**The pill must never take keyboard focus.** It is a `nonactivatingPanel` with
`canBecomeKey == false`. If it took focus there would be nothing left to paste into.

**A menu bar image has to be a template, and nothing tells you when it is not.** The idle glyph is
the app's own frog from `MenuBarIcon.imageset`, and the `template-rendering-intent` in its
`Contents.json` is what lets macOS throw the colours away and paint the shape to match the bar it
lands in. Without it the artwork ships as literal black pixels, which look right in every
screenshot taken on a light menu bar and disappear on a dark one — and the menu bar follows the
desktop picture, not the appearance setting, so "it works in Light Mode" proves nothing. Drawing a
light copy and a dark copy instead has the same fault with more files. `AppBundleTests` checks the
flag survived, because a template that stopped being one still renders.

The size is the other half: `MenuBarExtra` hands its label straight to the status item, which does
not resize it. 18 points is what a status item is given, so artwork of any other size arrives at
that size — and `.resizable()` on the label stretches the template to whatever the bar allows.

**Signing is tied to Accessibility permission.** macOS records the grant against the *designated
requirement* of the signature, not against the app's bytes or its name. An ad-hoc signature's
requirement is `cdhash H"…"` — one exact binary — so every rebuild and every release is a new app
that has been granted nothing, and the old entry stays in System Settings looking ticked while
applying to nothing. Signing with a certificate makes the requirement
`identifier "com.grozoww.ourwhisper" and certificate leaf = H"…"`, which any later build signed by
the same certificate satisfies. `./scripts/dev-cert.sh` does this for your rebuilds and
`./scripts/release-cert.sh` for public releases; the certificates are self-signed, and Apple is
not involved in either. Read "The signing trap" in `CONTRIBUTING.md` before debugging "dictation
stopped working after a rebuild". Losing the release key is not recoverable — every user re-grants
Accessibility once.

**A programmatically created `NSWindow` releases itself on `close()`.** ARC then releases it again
and the process dies. `Tests/ViewRenderingTests.swift` sets `isReleasedWhenClosed = false`.

**Unit tests use the app as their test host, so the app really launches.** `AppState.start()`
returns early under XCTest — otherwise every test run would begin a 600 MB model download and
install a system-wide event tap.

**Stores default to the real Application Support directory.** Every store takes a `directory:`
parameter for exactly one reason: a test that used the default would destroy the settings, modes,
vocabulary and history of whoever ran the suite. Use `TemporaryDirectory` from `Tests/TestSupport`.
`AppDirectories.support` also redirects to a temporary directory under XCTest as a backstop —
that backstop exists because this mistake was made once and silently rewrote real user data.

**Accessibility is granted per code signature, which for an ad-hoc build means per path.** A second
clone or a git worktree produces a second `OurWhisper.app` in a different DerivedData directory,
and a permission granted to one does not apply to the other — while System Settings still shows a
ticked OurWhisper. This presents as "I granted it and the app still says I did not". The Home
screen shows the running bundle path and warns when other builds exist; check that before
suspecting the permission code.

The "at a path" half is only true of an ad-hoc signature, whose designated requirement is a
`cdhash` — one exact binary, so every rebuild is a different app. Signed with a certificate, the
requirement is `identifier "com.grozoww.ourwhisper" and certificate leaf = H"…"` and the grant
follows the bundle identifier and the certificate *anywhere on disk*. That was measured: a bundle
with the right identifier and the right certificate, at an unrelated path, comes back trusted; the
same identifier with a different certificate does not. It is also the reason the in-app updater can
exist at all.

**The designated requirement is the entire security boundary of the in-app update, and it has to be
read before anything is written.** `SHA256SUMS` ships from the same GitHub release as the disk
image, so it catches a truncated download and nothing else. Gatekeeper never gets a look: a
`URLSession` download carries no quarantine flag, only `com.apple.provenance`, so there is no
assessment to fail. What is left is `BundleSignature`: read the *running* app's designated
requirement, then `SecStaticCodeCheckValidity` the incoming bundle against it. That single call
answers both questions at once — the release key was involved, and the Accessibility grant will
survive — which is why there is one check rather than two.

Three ways to get it wrong, all of which pass:

- **Reading the requirement after the swap.** `SecCodeCopySelf` resolves through the bundle's path,
  and after the swap that path holds the new app, so the check compares the incoming build against
  itself and cannot fail. `perform` reads it in its first statement for that reason.
- **Comparing the candidate's own designated requirement to the running one as strings.** A
  self-signed certificate's requirement is generated from whichever key signed it, and a bundle
  with a byte appended to `AppIcon.icns` reports a requirement identical to the genuine one. Only
  `SecStaticCodeCheckValidity` rejects either.
- **`kSecCSDoNotValidateResources`, or the `kSecCSBasicValidateOnly` that implies it.** It returns
  success on a bundle whose sealed resources were swapped, and saves about a millisecond.

An ad-hoc-signed build cannot self-update at all — nothing can satisfy a `cdhash` — so
`namesACertificate` refuses up front and points at `scripts/install.sh`, rather than installing and
letting dictation stop with no error.

**`open` on a bundle whose app is already running launches nothing, and exits 0 while doing it.**
LaunchServices matches the running instance by bundle identifier and merely activates it. Measured
three times out of three: the successor never started, the guard "did the spawn succeed" never
fired because the spawn reported success, and terminating left the Mac with no OurWhisper running
at all — which for a menu bar app is indistinguishable from a crash. `UpdateInstaller.relaunch`
uses `open -n`, and launches *before* terminating. `scripts/install.sh` gets away with plain `open`
only because it force-quits the app before installing; an app cannot do that to itself and still be
around to call `open`.

`-n` then means two instances exist for a moment, and `AppState.start()` installs a system-wide
event tap and loads a 600 MB model. The new copy is handed `--awaiting-pid <pid>` and
`waitForPredecessor` blocks on it — ten seconds, then on regardless, because a successor that
refuses to start because the old copy is wedged is worse than two event taps for an instant.

**The app is replaced by one filesystem operation, never by `rm -rf` and a copy.** `install.sh`
deletes the old bundle and `ditto`s the new one into place, which is right when a human is watching
a terminal and would leave an in-app update with no app at all if it were interrupted. Everything
is downloaded, checksummed, expanded and verified *beside* the installed app in an
`.itemReplacementDirectory` — which is on the destination's own volume, so the swap is a rename —
and `replaceItemAt` is the only thing that touches the app. The running process is unharmed: its
pages stay mapped to the old inode, which lives on unlinked until it exits. Copying over the bundle
in place instead reuses the inode and macOS kills the process on the next page-in, and `ditto`
straight onto the live bundle merges rather than replaces, leaving files the new signature does not
seal — the same silent failure that kills the Accessibility grant.

**A volume mounted under `TemporaryItems` cannot be read by the app, and a shell test will not
tell you.** The first real run of the updater failed at its first `ls` of the mounted image with
"you don't have permission to view it". The mount point was inside the `.itemReplacementDirectory`
staging area — `$TMPDIR/TemporaryItems/NSIRD_OurWhisper_…/mount` — and macOS's System Policy
treats any volume mounted under `TemporaryItems`, inside the `NSIRD_` directory or beside it, as
needing Full Disk Access, which never prompts and simply refuses. Measured from a
LaunchServices-launched app on macOS 26: the same image reads fine at `/Volumes`, `/tmp`, `$TMPDIR`
itself or `~/Library/Caches`. `UpdateInstaller.expand` mounts under `$TMPDIR` with a unique name
for that reason; the staging directory still holds the download and the expanded copy, because
those are ordinary files and the swap needs them on the destination's volume.

Three rounds of research and a shell reproduction all said the original layout worked, because
every probe ran from Terminal, which carries Full Disk Access the app does not have. **A test of
anything TCC-shaped has to run inside a real `.app` launched through LaunchServices** — that is
what `OURWHISPER_SELFTEST_UPDATE=1` is for, and what the throwaway `MountProbe.app` that found
this did.

**Padding a `Section` pads every row in it.** In a `List`, `Section { rows }.padding(.top, 10)`
does not put 10pt above the group — it puts 10pt above each row inside it, so the rows come out
taller than the rows in the group above and their selection highlights come out taller with them.
The sidebar shipped that way. The gap between groups is the section break itself; there is nothing
to add.

**A pane whose content cannot shrink is laid out past the window edge, and then clipped.** Two
shapes of this. `HSplitView` sizes each pane to its content's ideal width, so a detail pane with a
wide row overflows the window with no scroll bar and no reflow — `ModesView` and `HistoryView` both
use a plain `HStack` with an explicit list width for that reason. And a row whose text column has
no minimum width loses the negotiation entirely: `SettingsRow` used to let its label shrink to
nothing, which turned "Symbol" into one letter per line in a narrow mode editor. It now measures
in `SettingsRowLayout` and drops the control onto its own line instead. The window's `minWidth` is the
other half of that: it is set to what the widest screen actually needs, and lowering it puts the
squeeze back.

**The mouse pointer does not know where the keyboard focus is.** The pill used to pick its
display from `NSEvent.mouseLocation`, so parking the pointer on the laptop screen and typing on
the external one put the pill on a display the user was not looking at — which is
indistinguishable from the pill not appearing at all, and is what "the bubble does not show on my
second screen" actually was. `NSScreen.main` is not the fallback it looks like either: it means
"the screen with the key window", and this is an accessory app whose pill refuses key status, so
it answers with the menu bar screen wherever the user is. `PillWindowController.screen(showing:)`
asks the process the text is about to be pasted into instead, via `CGWindowListCopyWindowInfo` —
a window-server query that returns bounds and owner without entering the other process, because
this runs inside the event tap callback and an Accessibility round trip there blocks for as long
as the other app takes to answer. Largest overlap, not `contains`: a window straddling two
displays belongs to the one showing most of it. `kCGWindowBounds` measures down from the top of
the primary display and AppKit measures up from its bottom, so `flippedToAppKit` is load-bearing.
Spaces are a separate thing and already handled — `.canJoinAllSpaces` at `.statusBar` level is
what puts the pill above another app's full-screen window.

**An `NSScreen` is not a durable name for a display.** AppKit replaces every `NSScreen` object
when a display is added, removed, woken or re-resolutioned, and a retained one goes on reporting
geometry for a screen that is no longer there — so the next `setPhase` re-fit parks the pill at
coordinates nothing can draw at, for the rest of the dictation. `PillWindowController` stores the
`CGDirectDisplayID` and resolves it to a live `NSScreen` on every `reposition`, and observes
`NSApplication.didChangeScreenParametersNotification` because a display arriving or leaving moves
every other display's origin too. Register that observer in `init`, not off the first `show()`,
and follow `PermissionsManager`'s shape — a block observer on `.main` wrapped in
`MainActor.assumeIsolated`, with no `deinit`, which on a controller that lives for the process
would only be a Swift 6 warning for code that never runs.

**A window sized to its content view does not resize when the content does.** The pill's phases
are different widths — "Cleaning up" is wider than five audio bars — so setting `PillModel.phase`
directly leaves the panel at the previous width and the longer label is truncated and off centre.
Go through `PillWindowController.setPhase`, which re-fits and re-centres. `show()` also resets the
model, so it must be called *before* the phase is set, not after.

**A window clips its own contents, shadow included.** The pill's panel is sized to the SwiftUI
view, and the window server clips to the window frame, so a `.shadow` with nowhere to fall is cut
off square — the pill then appears to sit inside a translucent grey rectangle. `PillView` reserves
`shadowMargin` of transparent padding for it, and `PillWindowController.reposition` subtracts that
margin so the capsule stays where it was. Any floating overlay that draws its own shadow needs the
same room.

**The version number is derived, so it needs real history.** `scripts/version.sh` sets the patch
number from the pull requests merged since the `VERSION` file last changed, which means a shallow
clone — `actions/checkout`'s default — has no merges to count and every build comes out as x.y.0.
Both workflows pass `fetch-depth: 0` for that reason. Major and minor stay a hand edit to
`VERSION`; a `v*` tag on the built commit overrides the lot. `package.sh` stamps the result onto
`xcodebuild`, so `MARKETING_VERSION` in the project is only what a plain Xcode build falls back to
— keep it equal to `VERSION`, but do not treat it as the source of truth. Getting this wrong ships
an app that reports an older version than the release it came from, and `UpdateChecker` then
offers every user an update to what they are already running.

**A settings screen is built eagerly unless you say otherwise.** `SettingsPage` puts its sections
in a `LazyVStack`, not a `VStack`, so opening a screen builds only what is on display. A `Picker` is
about 6 ms to build and Configuration has seven of them; building the whole page up front is what
made switching sidebar rows take ~240 ms before anything appeared, against ~135 ms now. The rest of
that is SwiftUI tearing down one screen and building the next, which is what a `switch` in
`RootView.detail` means — measure before assuming one screen is at fault.

**`ViewThatFits` builds every candidate, and a settings page is one view.** Both halves matter
together. `SettingsRow` used to state its two arrangements as `ViewThatFits { sideBySide;
stacked }`, which is the clearest way to write it and meant every row built two copies of its
control — a `Picker` is expensive to build. And because a whole settings screen is a single
SwiftUI view reading one observed `Settings` value, flipping any switch re-renders every row on
it. Measured: 105 ms per change on Configuration, which is a toggle animating at about five
frames a second. `SettingsRowLayout` measures each subview once instead, and the same change now
costs 23 ms — one `dimensions(in:)` call per subview, which already carries the size, rather than
that *and* `sizeThatFits` for the same proposal.

If a screen ever feels slow again, measure it in the real app rather than in a test. `AppState.start`
returns early under XCTest, so a test host never runs the event tap, the model load or the permission
poll, and it reported roughly half the cost the shipped app actually pays. Add a temporary probe
behind an environment variable that changes state and waits for `CFRunLoopActivity.beforeWaiting`,
then run `sample` against the process while it churns. Release is not faster than Debug here — that
was measured — so a slow screen is a real defect, not a build-configuration artefact.

**Nothing in a SwiftUI body may ask the system a question — and a `@State` default is in the
body.** `LaunchAtLogin.status` is an XPC round trip to the background task daemon (~3 ms) and
`KeychainStore.has` is one to securityd; both were being read from `body`, where they ran several
times per render. Read them into `@State` on appear and refresh them when something changes them.
The same goes for `AudioDevices.inputs()`, which costs ~65 ms — `SoundView` already loads it in a
`.task`, and `AppState.inputDeviceName` only calls it when the user has pinned a device.

The half of that rule which is easy to miss is `@State private var status = LaunchAtLogin.status`.
A property's default is an ordinary expression, evaluated every time the struct is built even
though SwiftUI keeps only the first result — and a settings screen is one view, so it is rebuilt
whenever anything on it changes. That one line was 94% of the time spent evaluating
`ConfigurationView.body`, and it is why flipping a switch cost 19 ms rather than 10. Give `@State` a
cheap literal and fill it in from `.onAppear` or `.task`.

Polling counts too. `PermissionsManager` used to read `AVCaptureDevice.authorizationStatus` — about
13 ms on the main thread — every two seconds for the life of the process. Accessibility is the one
that has to be polled, because macOS never says it changed; the microphone can only change in
System Settings, so it is re-read when the app is activated instead. And because `@Observable`
publishes a write whether or not the value changed, a poll that writes the same answer back
invalidates every view watching it: compare before assigning.

**`SMAppService` reports `.notFound` for an app that has simply never registered.** It does not
mean the app is in the wrong place. The login-item switch used to disable itself on that status
and tell the user to move the app to /Applications, which left it greyed out on a correctly
installed copy; registering from `.notFound` works, and only `.requiresApproval` is a state code
cannot get out of. A self-signed app with no Team ID registers fine — verified by registering and
unregistering one.

**Bringing a window forward is not the same as wanting a Dock icon.** `WindowPresenter.activate`
used to set `.regular` unconditionally, so the app appeared in the Dock for as long as its window
was open no matter what "Show in the Dock" said — and the switch read as broken rather than as the
preference it is. An accessory app can hold a key window, take keyboard input, and run its menu
key equivalents (⌘W, ⌘Q, ⌘V in a text field all work — verified) without a Dock icon; it only has
to be told to activate. What it does *not* get is the menu bar at the top of the screen, which
keeps showing whichever regular app was in front. That is the whole cost of the toggle being off.

**A window belongs to the desktop it was created on.** The scene's window is created at launch, so
it lived on whichever desktop the app started on, and opening it from the menu bar on any other
desktop slid the user back there — activating an app switches to the desktop holding its windows.
`WindowPresenter.followsToCurrentDesktop` sets `.moveToActiveSpace` *before* `NSApp.activate`,
because activation is the moment the switch happens. The pill never had this problem:
`.canJoinAllSpaces` puts it on every desktop, which was measured rather than assumed.

**Launch at login is not a setting.** `LaunchAtLogin` reads `SMAppService.mainApp.status` every
time. Persisting it in `Settings` would create a second source of truth that drifts the moment
someone switches the login item off in System Settings, and the toggle would then lie about what
the Mac will actually do at the next login. Registration is also per bundle path, so a debug build
registers the copy in DerivedData — the same trap as Accessibility permission, below.

**`decodeIfPresent` cannot tell "absent" from "null".** For an optional field whose default is not
nil — `pushToTalkChord` is the live example — use
`container.optional(key, defaultWhenAbsent:)`, or upgrading users get nil instead of the new
default and the feature silently arrives switched off.

## Adding things

**A new transcription engine.** Conform to `TranscriptionProvider`, take an `HTTPClient` if it is
a cloud engine, and add it to `TranscriptionRouter`. Do not add a second *local* speech model
without benchmark numbers — the Parakeet-over-Whisper choice is documented in `README.md` with
FLEURS WER, and `CONTRIBUTING.md` requires evidence to change it.

**A cleanup rule.** Add it to `CleanupOptions`, implement it in `RuleRefiner`, wire the toggle into
`ModesView`, and add it to `Mode`'s `init(from:)`. Rules must be pure and fast: they run on every
dictation, including when the model is off. Anything needing judgement belongs in
`OnDeviceRefiner` instead.

**A setting.** Add the field with a default, add it to its section's `init(from:)`, and surface it
in the right screen. Never add a control without the sentence explaining it — `SettingsRow`
requires a `detail` for that reason.

**Anything users download.** `scripts/package.sh` builds the DMG and `scripts/install.sh` is the
`curl | bash` that installs it. There is no Apple Developer account behind this project, so
releases are signed with the self-signed `OurWhisper Release` certificate rather than notarized,
and macOS refuses to open them until the quarantine flag is cleared — which is the one thing
install.sh exists to do. Signing and notarizing are deliberately separate decisions in both
`package.sh` and the workflow: a self-signed certificate cannot be notarized, but it is what keeps
the Accessibility grant alive across updates, and treating the two as one flag is what made every
release ad-hoc. The same mistake one level up is what broke the update check: every release was
marked a prerelease because none was notarized, `/releases/latest` skips prereleases, and the app
read the resulting 404 as "up to date". Notarization decides whether Gatekeeper complains, not
whether a release is finished — merging to main is what decides that.

**Merging to main publishes a finished release, and it becomes the latest.** A pull request builds
and tests but does not package; a push to main packages and publishes, tagged
`release-<version>-<short sha>` so nothing is ever replaced; a `v*` tag does the same under its own
tag. Only a `workflow_dispatch` rehearsal is a prerelease, because that is a build nobody merged.
Every one of them is *named* `release-<version>-<short sha>`. Marking the main builds prereleases
is what kept the update check silent for the project's whole life: `UpdateChecker` skips
prereleases, no `v*` tag was ever cut, and so there was never anything for it to find.

The other half of that failure was in the tag itself. `UpdateChecker.normalise` stripped a leading
`v` and nothing else, so `release-1.0.8-71f957b` came out with a word in front of the numbers and
compared as 0.0.0 — the newest release read as older than whatever the user was already running.
It now takes the first run of dot-separated digits, and requires the dot so `build-7` does not read
as version 7. **A tag shape that carries the version must survive `normalise`**; if you change how
releases are tagged, change that with it.

**GitHub does not return the releases list newest first.** `GET /releases` came back with `v1.0.8`
ahead of 1.0.9, 1.0.10 and 1.0.7 — an order matching neither `id`, `created_at` nor `published_at`,
and GitHub documents no order at all. `install.sh` took the first DMG in that response, so
`curl | bash` installed 1.0.8 while `/releases/latest` correctly pointed at 1.0.10. It now asks
`/releases/latest` first and, only if that 404s, reads the version out of each DMG's *filename* and
takes the highest with `sort -V`. **Never read a GitHub releases list positionally.** And the same
mistake in miniature: plain `sort` puts 1.0.9 above 1.0.10, so the `-V` is not decoration.

That rule has two callers, and fixing one of them is what let this run for four more releases.
`UpdateChecker.newestFinishedRelease` took the first *finished* entry in the same list, on the same
false belief, written down in its own doc comment as "GitHub returns them newest first". The list
put `release-1.0.9-38ea901` ahead of 1.0.12, 1.0.11 and 1.0.10, so an app on 1.0.11 was told 1.0.9
was the newest, found it was not newer, and reported itself up to date — silently, and looking
perfectly healthy while doing it. It now takes the highest parsed version out of the whole list.
**Parse every entry's version and take the maximum; never trust a position.** Both callers, every
time.

The test is the other half of why it survived. `picksNewestFinishedRelease` was called "the newest
finished release in the list is the one offered" and its fixture was sorted newest first, so it
passed identically whether the code sorted or took element zero. **A fixture for an
order-independence claim must be out of order**, or it asserts nothing. `ignoresTheOrderGitHubReturns`
now uses the real response verbatim.

The checksum had the matching bug. `SHA256SUMS` was found by its own separate search over the same
response, so it could come from a different release than the DMG — and then the filename lookup
found nothing, `EXPECTED` came out empty, and the check was skipped in silence. It is now derived
from the DMG's own URL, and both skip paths say so out loud, because a check that quietly does
nothing reads exactly like one that passed.

The DMG is checked where it ships, not on the branch. `package.sh` exits zero on an image that is
subtly wrong — an asset catalog that failed to compile leaves the app with no icon — so
`release.yml` mounts the image and checks the app, the icon and the signature *before* Publish. A
failure there means no release is created, rather than one `UpdateChecker` goes on to offer people.
Packaging on every pull request checked a DMG nobody would download and cost five macOS minutes a
run; this replaces it.

**A dependency.** It must be pinned to an exact version, `Package.resolved` must be committed in
the same change, and `./scripts/audit-deps.sh` must pass. Two traps found the hard way, both
recorded in `CONTRIBUTING.md`: a package with a build-tool plugin needs Xcode's plugin trust, and
anything depending on `mlx-swift` 0.31.5+ needs Xcode's separately-downloaded Metal toolchain.

## Testing

Swift Testing, not XCTest. 199 tests, no network, no API key, no microphone, no permissions.

- Cloud providers are tested against `StubHTTPClient` with recorded response shapes.
- Every screen is built and laid out in `ViewRenderingTests` — a view that crashes on
  construction compiles fine and fails the first time someone clicks that sidebar row.
- The rule refiner has the deepest coverage because it is pure and it touches every dictation.

What is *not* covered, and why: the event tap, the paste path and CoreAudio device selection all
need permissions and real hardware. The second half of `UpdateInstaller` joins them —
`hdiutil attach`, `ditto`, `replaceItemAt`, `open -n` and a real `SecStaticCodeCheckValidity`
against the release certificate cannot run in CI, and the question they answer ("did the
Accessibility grant survive?") has no API. Everything up to the swap is covered: `fetch` runs
against `StubHTTPClient`, and the decisions — the checksum, the requirement's shape, whether the
bundle can be replaced — are pure. For the rest there is one command, and it is the only honest
test of the updater on a Mac:

```bash
OURWHISPER_SELFTEST_UPDATE=1 open /Applications/OurWhisper.app   # then ./scripts/run.sh --logs
```

It needs a build signed with the release certificate that reports a version *older* than the
newest release — `xcodebuild … MARKETING_VERSION=1.0.0` then `codesign` with the same flags
`package.sh` uses — installed at `/Applications`. Success is the process restarting into the new
version and the successor logging `Hotkey tap armed`, which it can only do if the Accessibility
grant survived. `CONTRIBUTING.md` asks for exactly that in a pull request, and it stays a human
answer.

## Style

Match the surrounding code. Specifically:

- Comments explain **why**, not what. If a line needs a comment saying what it does, rename
  something instead. Existing comments are the model — they document trade-offs, traps and
  decisions, not mechanics.
- Types get a doc comment saying what they are for and what the non-obvious constraint is.
- Prefer the plain word. The codebase says "loudness" rather than "amplitude envelope".
- User-facing strings say what to do about it. "Add a Soniox API key in Configuration", not
  "unauthorized".
