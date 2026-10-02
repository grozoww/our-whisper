import AppKit
import ApplicationServices
import OSLog

/// Puts transcribed text into whatever text field had focus when recording started.
///
/// Order of operations is the whole game here. The target is captured *before* any UI appears,
/// because showing a window — even a non-activating one — can change what `frontmostApplication`
/// reports. Paste then goes through the clipboard, because that is the only method every app
/// honours; direct Accessibility insertion is tried as a fallback for the apps that block it.
///
/// Going through the clipboard is also why "nowhere to paste" is a case at all. A frontmost app
/// with no caret in it swallows the ⌘V and says nothing, and the restore that follows puts the
/// user's old clipboard back over the text — so a dictation into a Finder window used to vanish
/// with a tick and the word "Finder" on the pill. `clipboardOnly` is that case handled.
///
/// Skipping the restore is the expensive half of that trade, so it is spent only on a definite
/// answer. `Acceptance` has three values for that reason, and `holdsOwnTranscript` is the other
/// side of it: once a transcript has been left on the clipboard, the app must not mistake it for
/// something the user copied and restore it over every dictation that follows.
@MainActor
final class TextInjector {
    enum Method: String, Sendable {
        case paste
        case accessibility
        case clipboardOnly
    }

    struct Target: Sendable {
        let processIdentifier: pid_t
        let applicationName: String
        let bundleIdentifier: String?

        init(_ app: NSRunningApplication) {
            processIdentifier = app.processIdentifier
            applicationName = app.localizedName ?? "the focused app"
            bundleIdentifier = app.bundleIdentifier
        }
    }

    enum InjectionError: LocalizedError {
        case noTarget
        case allMethodsFailed

        var errorDescription: String? {
            switch self {
            case .noTarget: "No app was focused when recording started."
            case .allMethodsFailed: "Could not paste. The text is on your clipboard."
            }
        }
    }

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "injection")

    /// How long to wait before putting the user's clipboard back. The paste is delivered
    /// asynchronously to the target app, and restoring too early pastes the *old* clipboard.
    private static let clipboardRestoreDelay = Duration.milliseconds(220)

    private var capturedTarget: Target?

    /// The `changeCount` of the last clipboard this app wrote itself.
    ///
    /// A number and nothing else. Keeping the text would mean holding a copy of whatever was last
    /// dictated — a password read aloud, someone's private message — for the life of the process,
    /// which is the thing `DictationController` drops its own copy to avoid.
    private var ownedChangeCount: Int?

    /// Accessibility's answer to "which app has the keyboard", asked off the main thread the moment
    /// the hotkey fires and collected by `confirmTarget()`.
    private var keyboardCheck: Task<pid_t?, Never>?

    // MARK: - Capture

    /// Called the instant the hotkey fires, before the pill is shown.
    ///
    /// The workspace's frontmost app is the answer almost always, and it is free. It is wrong for
    /// a non-activating window: Warp's hotkey window takes the keyboard without making Warp the
    /// frontmost app, so the workspace goes on naming whatever was underneath — measured on
    /// macOS 26, while Accessibility named Warp's text area. Every dictation into it was then
    /// aimed at the app below. Accessibility is asked as well, but on another thread: this runs
    /// inside the event tap callback, and a round trip to another process there is what makes
    /// macOS switch the tap off.
    func captureTarget() {
        capturedTarget = NSWorkspace.shared.frontmostApplication.map(Target.init)
        keyboardCheck = Task.detached(priority: .userInitiated) { Self.keyboardFocusedApplication() }

        log.debug("Captured target: \(self.capturedTarget?.applicationName ?? "none", privacy: .public)")
    }

    /// Swaps the captured app for the one that really had the keyboard, when the two differ.
    ///
    /// Called when the recording ends, by which time the check started in `captureTarget` has long
    /// since answered — and before anything reads the target to pick a mode or record History.
    func confirmTarget() async {
        guard let check = keyboardCheck else { return }
        keyboardCheck = nil
        let focused = await check.value

        let owner = Self.keyboardOwner(
            frontmost: capturedTarget?.processIdentifier,
            focused: focused,
            focusedPolicy: focused.flatMap { NSRunningApplication(processIdentifier: $0)?.activationPolicy }
        )
        guard let owner, owner != capturedTarget?.processIdentifier,
              let app = NSRunningApplication(processIdentifier: owner)
        else { return }

        capturedTarget = Target(app)
        log.info("The keyboard was in \(self.capturedTarget?.applicationName ?? "?", privacy: .public), not the frontmost app")
    }

    /// Which app the text is for: the frontmost one, unless Accessibility put the keyboard in a
    /// different *regular* app.
    ///
    /// Regular only, for the reason `belongs(owner:to:ownerPolicy:)` gives: an Open panel, web
    /// content and the other remote views answer from processes with no app of their own, and
    /// their answer is about the frontmost app rather than against it. A nil from Accessibility is
    /// a failed question, not a different answer, so it changes nothing.
    nonisolated static func keyboardOwner(
        frontmost: pid_t?,
        focused: pid_t?,
        focusedPolicy: NSApplication.ActivationPolicy?
    ) -> pid_t? {
        guard let focused, focused != frontmost, focusedPolicy == .regular else { return frontmost }
        return focused
    }

    /// The app Accessibility says has keyboard focus, or nil when it could not say.
    private nonisolated static func keyboardFocusedApplication() -> pid_t? {
        var application: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedApplicationAttribute as CFString,
            &application
        ) == .success, let application else { return nil }

        var pid: pid_t = 0
        return AXUIElementGetPid(application as! AXUIElement, &pid) == .success ? pid : nil
    }

    var targetName: String? { capturedTarget?.applicationName }

    /// Bundle identifier of the app that had focus. Used to pick a mode automatically, which is
    /// why it is read at capture time along with everything else rather than looked up later.
    var targetBundleID: String? { capturedTarget?.bundleIdentifier }

    /// The process the text is going to. The pill uses it to find the display the user is working
    /// on, which is not the display the mouse pointer happens to be sitting on.
    var targetProcessIdentifier: pid_t? { capturedTarget?.processIdentifier }

    // MARK: - Injection

    /// Puts the text where it belongs and says how it got there.
    ///
    /// `keepWhenNothingFocused` is `DictationSettings.keepOnClipboardWhenNothingFocused`, and it
    /// only ever decides whether the *restore* happens. The keystroke is posted either way.
    @discardableResult
    func inject(_ text: String, keepWhenNothingFocused: Bool) async throws -> Method {
        guard !text.isEmpty else { return .paste }

        guard let target = capturedTarget else {
            // Nothing was frontmost at all, so there is no app to activate and no field to reach.
            // The clipboard is the only place left that is better than dropping the text.
            guard keepWhenNothingFocused else { throw InjectionError.noTarget }
            writeToClipboard(text)
            return .clipboardOnly
        }

        // The user may have switched apps while we transcribed. Put their original app back in
        // front, otherwise the text lands somewhere they were not looking.
        //
        // Not when the keyboard never left. A non-activating window — Warp's hotkey window — has
        // it without its app ever being frontmost, so the workspace disagrees with the target on
        // every dictation into one. Activating the app then is worse than useless: Warp hides that
        // window the moment it loses focus. Accessibility is only asked when the workspace
        // disagrees, so an ordinary dictation pays nothing for this.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier,
           Self.keyboardFocusedApplication() != target.processIdentifier,
           let app = NSRunningApplication(processIdentifier: target.processIdentifier) {
            app.activate()
            try? await Task.sleep(for: .milliseconds(60))
        }

        // Asked before the clipboard is touched, so the answer is about the field the user was in
        // rather than about anything the paste left behind.
        let (acceptance, element) = focusedTextElement(of: target)
        let nowhereToPaste = keepWhenNothingFocused && acceptance == .refuses

        // A clipboard this app left behind on an earlier dictation is not the user's clipboard.
        // Putting it back would make one failed paste permanent: every dictation after it would
        // faithfully restore the one before, and the thing the user actually copied would never
        // come back. See `holdsOwnTranscript`.
        let saved = holdsOwnTranscript ? nil : PasteboardSnapshot.capture()
        writeToClipboard(text)

        // Read after any activation above, so this is only true when the keyboard really is in a
        // window whose app is not frontmost.
        let keyboardIsInBackgroundApp =
            NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier

        if postPasteKeystroke(directlyTo: keyboardIsInBackgroundApp ? target.processIdentifier : nil) {
            // The keystroke went out regardless — the verdict is not trusted enough to cancel a
            // paste. What changes is that the old clipboard does not come back over the top of
            // text that had nowhere to land.
            guard !nowhereToPaste else {
                log.info("The focused element refused text; the transcript is left on the clipboard")
                return .clipboardOnly
            }

            // Restore in the background so the caller is not blocked on the delay.
            if let saved {
                Task { [saved] in
                    try? await Task.sleep(for: Self.clipboardRestoreDelay)
                    saved.restore()
                }
            }
            return .paste
        }

        log.warning("Synthetic paste failed; trying Accessibility insertion")
        if injectViaAccessibility(text, into: element) {
            saved?.restore()
            return .accessibility
        }

        // Both failed. Leave the text on the clipboard rather than restoring — the user can still
        // paste it themselves, which is better than losing what they just said.
        log.error("All injection methods failed; text left on clipboard")
        throw InjectionError.allMethodsFailed
    }

    // MARK: - Methods

    /// Synthesizes ⌘V.
    ///
    /// `privateState` matters: with the shared session state, the event inherits whatever
    /// modifiers are physically held. During push-to-talk the user is *still holding* the hotkey
    /// modifiers, so the paste would arrive as ⌥⌘⌃⇧V and do nothing.
    ///
    /// `pid` is set only when the keyboard is in a non-activating window of an app that is not
    /// frontmost — Warp's hotkey window. An event posted at the annotated session tap goes to the
    /// *frontmost app*, not to the window holding the keyboard: measured with two stand-in apps
    /// on macOS 26, ⌘V posted there landed in the app underneath every time, while the same event
    /// posted to the panel's pid landed in the panel. That is the other half of "dictating into
    /// Warp pastes into the app below". Every other dictation keeps the annotated tap it has
    /// always used.
    private func postPasteKeystroke(directlyTo pid: pid_t?) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKeyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        if let pid {
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
        } else {
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
        return true
    }

    /// Writes into the focused element directly. Works in standard AppKit text views and fails
    /// silently in others — combo boxes in particular accept the call and do nothing — which is
    /// why this is the fallback and not the primary path.
    private func injectViaAccessibility(_ text: String, into element: AXUIElement?) -> Bool {
        guard let element else { return false }
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return status == .success
    }

    private func writeToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownedChangeCount = pasteboard.changeCount
    }

    /// True while the clipboard is still the transcript this app put there, untouched since.
    ///
    /// `NSPasteboard.changeCount` moves on any write by any process, so equality is the whole
    /// test — no copy of the text has to be kept to answer it, and the moment the user copies
    /// something the answer goes back to false on its own.
    private var holdsOwnTranscript: Bool {
        ownedChangeCount == NSPasteboard.general.changeCount
    }

    /// What the user has on the clipboard, or nil when what is there is this app's own leftover
    /// transcript.
    ///
    /// A dictation that had nowhere to land stays on the clipboard on purpose. Reading it back on
    /// the next dictation — as context for the model, or as text to append — would quote the user
    /// their own last sentence and call it something they copied.
    func userClipboard() -> String? {
        holdsOwnTranscript ? nil : ClipboardContext.current()
    }

    /// What the focused element had to say about taking text.
    ///
    /// Three answers, not two, and that is the whole fix. "The app did not answer" and "there is
    /// nothing here that takes text" used to arrive as the same `false`, and the app acted on it
    /// in the destructive direction: it kept the transcript on the clipboard and never put back
    /// what the user had copied. A busy Chrome, an Electron app still building its accessibility
    /// tree, an element rebuilt while we were transcribing — every one of those looked exactly
    /// like an empty desktop, and every one of them cost the user their clipboard while the paste
    /// visibly worked.
    enum Acceptance: Equatable, Sendable {
        /// The element takes text, or looks enough like something that does.
        case accepts
        /// A real answer, in the negative. The only verdict that keeps the transcript on the
        /// clipboard.
        case refuses
        /// Accessibility could not or would not say. Costs a restore that may not have been
        /// needed; the alternative costs the user their clipboard.
        case unknown
    }

    /// Turns what Accessibility said into the verdict.
    ///
    /// Pure, so the one decision in this file that costs the user their clipboard when it is
    /// wrong can be tested — the AX calls that feed it cannot be. `settable` and `role` are nil
    /// when the query *failed* rather than answered, which is the distinction the old code did
    /// not have.
    nonisolated static func acceptance(
        focus: AXError,
        belongsToTarget: Bool,
        settable: Bool?,
        role: String?
    ) -> Acceptance {
        // The one error that is an answer rather than a failure: the frontmost app is saying
        // nothing has the caret. A Finder window, a PDF in Preview, an empty desktop — the case
        // this whole check exists for.
        if focus == .noValue { return .refuses }
        guard focus == .success, belongsToTarget else { return .unknown }

        if settable == true { return .accepts }

        // Plenty of apps decline to call the attribute settable and still accept a paste, so the
        // role gets a say before the answer is no. A role that answered is evidence either way; a
        // role that did not answer is not evidence at all.
        guard let role else { return .unknown }
        return textRoles.contains(role) ? .accepts : .refuses
    }

    /// Whether an element vended by `owner` is evidence about `target`.
    ///
    /// A plain app answers with its own pid, so usually this is one comparison. The exception is
    /// the reason this is not one line: macOS routinely vends the focused element from a process
    /// that is not the app — an Open or Save panel comes from
    /// `com.apple.appkit.xpc.openAndSavePanelService`, web content from
    /// `com.apple.WebKit.WebContent`, share sheets and pickers from their own remote view
    /// services. Those are not "some other app the user switched to"; they have no app of their
    /// own, which is exactly what a non-regular activation policy means, and their answer is
    /// evidence about whatever is hosting them.
    ///
    /// Getting this wrong in the strict direction loses a dictation: a file list in a sandboxed
    /// app's Open panel is a real refusal, and demoting it to `.unknown` restores the old
    /// clipboard over a transcript the panel swallowed.
    nonisolated static func belongs(
        owner: pid_t?,
        to target: pid_t,
        ownerPolicy: NSApplication.ActivationPolicy?
    ) -> Bool {
        guard let owner else { return false }
        if owner == target { return true }
        // Nil means the pid is not a registered application at all, which is the same answer.
        guard let ownerPolicy else { return true }
        return ownerPolicy != .regular
    }

    /// Asks the app in front right now what has the caret, and whether it takes text.
    ///
    /// Read here rather than in `captureTarget`, which runs inside the event tap callback: a
    /// round trip to another process there is exactly the work that makes macOS switch the tap
    /// off. Reading it here also means the answer is about the element that has focus *now*
    /// rather than about a handle taken before a transcription that ran for several seconds —
    /// Chromium and Electron rebuild their accessibility nodes constantly, and a stale handle
    /// answers `kAXErrorInvalidUIElement` to everything while the field is still sitting there
    /// with a caret in it.
    ///
    /// The pid check is the other half. `app.activate()` above is asynchronous, so system-wide
    /// focus may still belong to whatever the user switched to while we transcribed, and another
    /// app's text field is not evidence about this one. See `belongs(owner:to:ownerPolicy:)` for
    /// why a foreign pid is not automatically a foreign app.
    private func focusedTextElement(of target: Target) -> (Acceptance, AXUIElement?) {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)

        guard status == .success, let focused else {
            return (Self.acceptance(focus: status, belongsToTarget: false, settable: nil, role: nil), nil)
        }
        let element = focused as! AXUIElement

        var pid: pid_t = 0
        let owner: pid_t? = AXUIElementGetPid(element, &pid) == .success ? pid : nil
        let belongsToTarget = Self.belongs(
            owner: owner,
            to: target.processIdentifier,
            ownerPolicy: owner.flatMap { NSRunningApplication(processIdentifier: $0)?.activationPolicy }
        )

        var isSettable = DarwinBoolean(false)
        let settable = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSettable) == .success
            ? isSettable.boolValue
            : nil

        var roleValue: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success
            ? roleValue as? String
            : nil

        let verdict = Self.acceptance(
            focus: status,
            belongsToTarget: belongsToTarget,
            settable: settable,
            role: role
        )
        return (verdict, belongsToTarget ? element : nil)
    }

    /// Roles that mean a paste has somewhere to go.
    ///
    /// `AXWebArea` is here not because a page is a text field but because Chromium and Electron
    /// hand out one of them for a whole page instead of an element per input, and a browser will
    /// not tell us which part of it has the caret.
    nonisolated static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXWebArea",
    ]
}

/// A copy of the clipboard deep enough to put back exactly what was there — every item, every
/// representation. Copying only the string would quietly destroy a copied image or file.
struct PasteboardSnapshot: Sendable {
    private let items: [[String: Data]]

    static func capture() -> PasteboardSnapshot {
        let contents = NSPasteboard.general.pasteboardItems ?? []
        let copied = contents.map { item in
            var representations: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type.rawValue] = data
                }
            }
            return representations
        }
        return PasteboardSnapshot(items: copied)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
