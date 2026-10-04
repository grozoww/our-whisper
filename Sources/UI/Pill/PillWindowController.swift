import AppKit
import OSLog
import SwiftUI

/// Owns the floating recording overlay.
///
/// The window must never take keyboard focus. That is not a nicety: the app pastes into whatever
/// field was focused, so if the pill stole focus there would be nothing left to paste into. Hence
/// `nonactivatingPanel`, `canBecomeKey == false`, and mouse events passed straight through.
@MainActor
final class PillWindowController {
    private var panel: PillPanel?
    private let model = PillModel()

    /// The display the current pill belongs to, fixed for as long as it is up.
    ///
    /// Stored as the display's id, not as the `NSScreen`. AppKit replaces every `NSScreen` object
    /// when a display is added, removed, woken or re-resolutioned, and a retained one goes on
    /// reporting the geometry of a screen that is no longer there — so the next re-fit puts the
    /// pill at coordinates nothing can draw at, and it is simply not on screen any more.
    private var displayID: CGDirectDisplayID?

    private var screenObserver: NSObjectProtocol?

    /// The timer started by `dismiss(after:)`, kept so the next `show()` can call it off.
    private var dismissal: Task<Void, Never>?

    /// The wait before the pill opens into the mode picker, kept so stopping first can cancel it.
    private var expansion: Task<Void, Never>?

    /// How long the small pill is up before it opens. Long enough to read as the pill appearing
    /// and *then* growing, which is the effect; short enough that someone choosing a mode is not
    /// waiting on it. A dictation that ends first never sees it open.
    static let expansionDelay = Duration.milliseconds(320)

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "pill")

    var pillModel: PillModel { model }

    /// What `screencapture -l` needs to photograph just the pill. See `ScreenshotMode`.
    var windowNumber: Int? { panel?.windowNumber }

    init() {
        // A display arriving, leaving, waking or changing resolution moves every other display's
        // origin as well. Without this the pill stays parked at the coordinates it was given, which
        // may now be behind a bezel or on nothing at all. Registered here rather than off the first
        // `show()`, so it does not depend on whether anyone has dictated yet; there is no teardown
        // because this controller lives for the life of the process, and a `deinit` reaching back
        // into main-actor state is a Swift 6 warning for the sake of code that never runs.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.reposition(panel)
            }
        }
    }

    /// Puts the pill up on the display `processIdentifier` is working on.
    ///
    /// The pid is the app the text is about to be pasted into — `TextInjector` has just captured
    /// it. Nil falls back to the pointer, which is all an error pill raised before there is a
    /// target has to go on.
    func show(focusedIn processIdentifier: pid_t? = nil) {
        // A dismissal still pending from the last dictation would otherwise hide this one: start
        // talking within 0.7 s of a paste, or 2.5 s of "Nothing was said", and the pill vanished
        // for the whole of the new dictation.
        dismissal?.cancel()
        expansion?.cancel()
        model.reset()
        let panel = panelOnThisDesktop()
        // A pill does not take clicks. The one with a picker asks for them in `offerModes`, once it
        // is open, and gives them back the moment it closes.
        panel.ignoresMouseEvents = true
        // Chosen once, here, rather than on every re-fit: the pill belongs on the screen the user
        // started dictating on, and re-reading it would make it hop displays mid-sentence.
        displayID = Self.identifier(of: Self.screen(showing: processIdentifier))
        reposition(panel)
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront` — the latter would do exactly
        // the thing this window must never do.
        panel.orderFrontRegardless()
    }

    /// The only way the phase should be changed.
    ///
    /// Each phase has a different width — "Cleaning up" is wider than five audio bars — and a
    /// window sized to its content view is not resized by that content changing. Setting the model
    /// directly leaves the panel at the previous phase's width, which truncates the longer label
    /// and pushes the pill off centre. Re-fitting here is what keeps that from being something
    /// every call site has to remember.
    func setPhase(_ phase: PillModel.Phase) {
        model.phase = phase
        if phase != .listening { closePicker() }
        guard let panel else { return }
        reposition(panel)
    }

    /// Gives this dictation's pill a mode picker, and opens it a moment from now.
    ///
    /// Called after `show()`, which clears the picker — a pill that is only a message has none.
    /// The window is made as big as the open pill from here on, so what opens is the capsule
    /// inside it and the window itself never has to be animated.
    ///
    /// Returns the wait before it opens, so a test can wait on that and not on a fixed time.
    @discardableResult
    func offerModes(
        _ options: [PillModeOption],
        selected: UUID?,
        onSelect: @escaping (UUID) -> Void
    ) -> Task<Void, Never> {
        model.modeOptions = options
        model.selectedModeID = selected
        model.onSelectMode = onSelect
        if let panel { reposition(panel) }

        expansion?.cancel()
        let opening = Task { [weak self] in
            try? await Task.sleep(for: Self.expansionDelay)
            guard !Task.isCancelled, let self, self.model.phase == .listening, self.model.hasPicker else { return }
            self.model.isExpanded = true
            // Only now does the window take clicks, and only for as long as it is open.
            self.panel?.ignoresMouseEvents = false
        }
        expansion = opening
        return opening
    }

    /// Whether the pill is taking clicks. Only the open picker does.
    var takesClicks: Bool { panel.map { !$0.ignoresMouseEvents } ?? false }

    /// Moves the ring to another mode, without announcing it back to whoever is listening.
    func selectMode(_ id: UUID?) {
        model.selectedModeID = id
    }

    private func closePicker() {
        expansion?.cancel()
        model.isExpanded = false
        panel?.ignoresMouseEvents = true
    }

    func hide() {
        closePicker()
        panel?.orderOut(nil)
    }

    /// Leaves the pill up briefly so the user sees the result, then dismisses it.
    ///
    /// Returns the timer so a test can wait for it to finish. Waiting a fixed time instead failed
    /// one run in four: a 20 ms timer took up to 465 ms to fire while other suites held the main
    /// thread.
    @discardableResult
    func dismiss(after delay: Duration) -> Task<Void, Never> {
        dismissal?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            // `try?` swallows the cancellation along with everything else, so it has to be asked.
            guard !Task.isCancelled else { return }
            self?.hide()
        }
        dismissal = task
        return task
    }

    /// The panel, or a new one if macOS has taken the old one off this desktop.
    ///
    /// `.canJoinAllSpaces` is not something AppKit keeps true; the window server can stop honouring
    /// it on a window that is hidden. Measured on a pill that had stopped appearing: the window
    /// still carried the flag, AppKit still reported it, and the window server listed it on one
    /// desktop only. `orderFrontRegardless` then put it up on that desktop, and every dictation
    /// anywhere else ran with no pill and no error. Setting `collectionBehavior` again does not
    /// bring it back, the same value or cleared and set; only a new window does.
    ///
    /// What strands it is not established. The Mac had slept and woken in the half hour before,
    /// which makes that a suspect and nothing more — the check does not depend on the cause.
    ///
    /// Checked here rather than rebuilt every time because this runs inside the event tap
    /// callback: `isOnActiveSpace` is a couple of microseconds, and a new panel is 10–25 ms.
    private func panelOnThisDesktop() -> PillPanel {
        if let panel, panel.isOnActiveSpace { return panel }
        if let stranded = panel {
            log.notice("Pill window was left on another desktop; replacing it")
            stranded.orderOut(nil)
        }
        let fresh = makePanel()
        panel = fresh
        return fresh
    }

    private func makePanel() -> PillPanel {
        let panel = PillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the SwiftUI capsule draws its own, correctly shaped
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Follow the user across spaces and sit above full-screen apps, because dictation is used
        // inside other apps' full-screen windows more often than not.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: PillView().environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    /// Bottom-centre of the screen picked in `show()`, so the pill appears where the user is
    /// working rather than always on the main display.
    private func reposition(_ panel: NSPanel) {
        guard let frame = currentScreen()?.visibleFrame else { return }

        // `layoutIfNeeded` alone returns the size from before the phase changed; the hosting view
        // has to be invalidated first or the panel keeps the old width.
        panel.contentView?.invalidateIntrinsicContentSize()
        panel.layoutIfNeeded()
        let margin = PillView.shadowMargin
        let size = panel.contentView?.fittingSize ?? NSSize(width: 140 + margin * 2, height: 44 + margin * 2)
        // The window is bigger than the capsule by the shadow margin on every side, so the offset
        // is measured to the capsule rather than to the window. Otherwise turning the margin up
        // would quietly push the pill further from the bottom of the screen.
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96 - margin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// The pill's display, resolved fresh every time rather than held. See `displayID`.
    private func currentScreen() -> NSScreen? {
        if let displayID, let live = NSScreen.screens.first(where: { Self.identifier(of: $0) == displayID }) {
            return live
        }
        // The display it was on has gone. Anywhere visible beats nowhere.
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func identifier(of screen: NSScreen?) -> CGDirectDisplayID? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The display the user is actually working on.
    ///
    /// This used to be the mouse pointer, and the pointer is the one thing in the system that is
    /// guaranteed not to track keyboard focus: park the mouse on the laptop screen, type on the
    /// external one, and the pill appears on a display the user is not looking at — which is
    /// indistinguishable from the pill not appearing. `NSScreen.main` is no better here, because
    /// it means "the screen with the key window" and this is an accessory app whose pill refuses
    /// key status, so it answers with the menu bar screen no matter where the user is.
    ///
    /// The app already knows which process it is about to paste into, so the honest answer is that
    /// process's frontmost window. Failing that — a process with no on-screen window, or no target
    /// at all — the pointer is still the best guess available.
    private static func screen(showing processIdentifier: pid_t?) -> NSScreen? {
        guard let processIdentifier, let window = frontmostWindowFrame(of: processIdentifier) else {
            return screenUnderPointer()
        }

        // Largest overlap rather than `contains`: a window straddling two displays belongs to the
        // one showing most of it, which is the one the user is looking at.
        let best = NSScreen.screens.max {
            $0.frame.intersection(window).area < $1.frame.intersection(window).area
        }
        guard let best, best.frame.intersects(window) else { return screenUnderPointer() }
        return best
    }

    /// The frontmost on-screen window belonging to a process, in AppKit coordinates.
    ///
    /// The window list rather than Accessibility, because this runs on the way into recording —
    /// inside the event tap callback — and an AX round trip into another app blocks for as long as
    /// that app takes to answer, which is exactly the work that makes macOS switch the tap off.
    /// `CGWindowListCopyWindowInfo` is a window-server query that returns bounds and owner without
    /// entering the other process, and it needs no permission the app does not already have.
    private static func frontmostWindowFrame(of processIdentifier: pid_t) -> NSRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Front to back, so the first window this process owns is the one in front. Layer 0 is an
        // ordinary window; anything above it is a panel, a menu or a status item.
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            return flippedToAppKit(rect)
        }
        return nil
    }

    /// The window list measures down from the top of the primary display; AppKit measures up from
    /// its bottom. Comparing the two without this puts a window on the wrong screen whenever the
    /// displays are not stacked the way the naive reading assumes.
    private static func flippedToAppKit(_ rect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}

private extension NSRect {
    /// Zero for `CGRect.null`, which is what a miss from `intersection` is.
    var area: CGFloat { isNull ? 0 : width * height }
}

/// A borderless panel refuses key status by default only when it is not `nonactivating`; being
/// explicit costs one line and removes any doubt.
private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
