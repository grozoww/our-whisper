import AppKit
import SwiftUI

/// Poses one screen of the app with demo data and holds it there, so something outside the app
/// can take the picture. This is where the README's screenshots come from.
///
/// Two things force this shape. The window is only reachable by clicking a menu bar icon, which
/// nothing automated can do — the same reason `OURWHISPER_SECTION` exists. And the app cannot
/// photograph itself: screen recording is granted per bundle, a debug build's bundle path changes
/// with the checkout, and a fresh one has been granted nothing — while the terminal running
/// `scripts/screenshots.sh` already has it. So the app poses and prints the window number, and
/// the script presses the shutter.
///
///     OURWHISPER_SCREENSHOT=modes OURWHISPER_SCREENSHOT_THEME=dark <binary>
///     OURWHISPER_SCREENSHOT=modes OURWHISPER_SCREENSHOT_SIZE=880x560 <binary>
///     OURWHISPER_SCREENSHOT=modes OURWHISPER_SCREENSHOT_SIDEBAR=collapsed <binary>
///     OURWHISPER_SCREENSHOT=pill.listening <binary>
///     OURWHISPER_SCREENSHOT=pill.picker <binary>
///     OURWHISPER_SCREENSHOT=modes.icons <binary>
///     OURWHISPER_SCREENSHOT=modes.assistant <binary>
///
/// The data in the picture is seeded below, never the user's: screenshot mode redirects
/// `AppDirectories.support` to a throwaway directory, for the same reason the tests do.
@MainActor
enum ScreenshotMode {
    enum Target {
        case section(NavigationSection)
        case pill(PillModel.Phase, withModes: Bool = false, opens: Bool = false)

        init?(rawValue: String) {
            if let section = NavigationSection(rawValue: rawValue) {
                self = .section(section)
                return
            }
            switch rawValue {
            // The Modes screen with the icon picker open. Not a README shot: the popover is a
            // window of its own, so `screencapture -l` of the main window leaves it out. Take the
            // whole display instead.
            case "modes.icons": self = .section(.modes)
            // The Modes screen on the shipped assistant, "Ask", which is what the editor changes
            // shape for.
            case "modes.assistant": self = .section(.modes)
            case "pill.listening": self = .pill(.listening)
            case "pill.transcribing": self = .pill(.transcribing)
            case "pill.cleaning": self = .pill(.formatting)
            case "pill.answering": self = .pill(.answering)
            // The pill open into its mode picker, with the shipped modes.
            case "pill.picker": self = .pill(.listening, withModes: true)
            // Reported ready at once, with the picker still to open by itself: for photographing the
            // opening a frame at a time.
            case "pill.opening": self = .pill(.listening, withModes: true, opens: true)
            case "pill.pasted": self = .pill(.success("Pasted into Slack"))
            default: return nil
            }
        }
    }

    /// Fixed, so two runs of the script produce two images that can be diffed. Close to the
    /// window's own minimum on purpose: a taller window only adds empty space below the Home
    /// screen's three rows, and empty space is what a screenshot has least use for.
    ///
    /// `OURWHISPER_SCREENSHOT_SIZE=880x560` overrides it. Layouts break at the small end, and the
    /// small end is the one nobody looks at — this is how to look at it without dragging a corner.
    static var windowSize: NSSize {
        guard let raw = ProcessInfo.processInfo.environment["OURWHISPER_SCREENSHOT_SIZE"] else {
            return NSSize(width: 1000, height: 600)
        }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return NSSize(width: 1000, height: 600) }
        return NSSize(width: parts[0], height: parts[1])
    }

    /// `OURWHISPER_SCREENSHOT_SIDEBAR=collapsed` hides the sidebar. What the detail pane does with
    /// the extra width is one thing; what the screens with a list of their own do when they become
    /// the leftmost thing in the window is another, and it is only visible this way.
    ///
    /// Set either way, never left alone: AppKit autosaves whether the sidebar is collapsed under
    /// the app's own defaults domain, which a debug build shares with the installed one. Someone
    /// who collapsed the sidebar in the real app would otherwise get README screenshots with no
    /// sidebar in them.
    static var sidebarCollapsed: Bool {
        ProcessInfo.processInfo.environment["OURWHISPER_SCREENSHOT_SIDEBAR"] == "collapsed"
    }

    nonisolated static var isActive: Bool { requestedRawValue != nil }

    nonisolated static var requestedRawValue: String? {
        ProcessInfo.processInfo.environment["OURWHISPER_SCREENSHOT"]
    }

    /// Whether the Modes editor should open its icon picker by itself.
    nonisolated static var opensIconPicker: Bool { requestedRawValue == "modes.icons" }

    static var requested: Target? { requestedRawValue.flatMap(Target.init(rawValue:)) }

    /// Light and dark are two separate pictures in the README, and the machine taking them has
    /// its own idea of which one it is in.
    static var requestedTheme: Theme {
        ProcessInfo.processInfo.environment["OURWHISPER_SCREENSHOT_THEME"]
            .flatMap(Theme.init(rawValue:)) ?? .system
    }

    /// Arranges the shot and then does nothing forever. The script kills the process once it has
    /// the picture; there is no other exit, because quitting on a timer would race the shutter.
    static func run(appState: AppState) async {
        guard let target = requested else {
            report("SCREENSHOT FAILED unknown target \(requestedRawValue ?? "")")
            return
        }

        seed(appState)

        switch target {
        case .section(let section): await pose(section: section, appState: appState)
        case .pill(let phase, let withModes, let opens): await pose(pill: phase, withModes: withModes, opens: opens)
        }
    }

    // MARK: - Posing

    private static func pose(section: NavigationSection, appState: AppState) async {
        appState.selectedSection = section
        WindowPresenter.activate()

        guard let window = await settledWindow() else {
            report("SCREENSHOT FAILED no window")
            return
        }

        // Before the resize: uncollapsing the sidebar widens the window to make room for it, so
        // doing it afterwards would hand back a window wider than the size asked for.
        setSidebar(collapsed: sidebarCollapsed, in: window)
        try? await Task.sleep(for: .milliseconds(300))

        // SwiftUI restores the window's last frame from `UserDefaults`, which is shared with
        // whatever size the person running this last dragged the real app to.
        window.setContentSize(windowSize)
        window.center()
        window.makeKeyAndOrderFront(nil)

        // One more settle: the resize relays out the split view, and capturing before that
        // finishes catches the sidebar mid-animation.
        try? await Task.sleep(for: .milliseconds(600))
        report("SCREENSHOT READY \(window.windowNumber)")
    }

    private static func pose(pill phase: PillModel.Phase, withModes: Bool, opens: Bool) async {
        let controller = PillWindowController()
        controller.show()
        if withModes {
            // Chosen by hand: the second shipped mode, so the ring is not on the first icon where
            // it could be mistaken for the default.
            controller.offerModes(Mode.builtIns.map(PillModeOption.init), selected: Mode.builtIns[1].id) { id in
                controller.selectMode(id)
            }
            if !opens { controller.pillModel.isExpanded = true }
        }
        // Bars frozen at a shape that reads as speech rather than the flat line of silence.
        for level in [0.35, 0.72, 0.28, 0.95, 0.55] as [Float] {
            controller.pillModel.push(level: level)
        }
        controller.setPhase(phase)

        if !opens { try? await Task.sleep(for: .milliseconds(900)) }

        guard let number = controller.windowNumber else {
            report("SCREENSHOT FAILED no pill")
            return
        }
        report("SCREENSHOT READY \(number)")

        // Nothing else holds the controller, and releasing it takes the pill off screen before
        // the shutter. Sleeping here is what keeps it alive.
        while true { try? await Task.sleep(for: .seconds(60)) }
    }

    /// `NavigationSplitView` is an `NSSplitViewController` underneath, reachable as the split
    /// view's delegate rather than through the window's content view controller. Setting
    /// `isCollapsed` rather than sending `toggleSidebar:` is what makes the result the same
    /// whichever state the autosaved defaults arrived in.
    private static func setSidebar(collapsed: Bool, in window: NSWindow) {
        guard let split = splitView(in: window.contentView),
              let controller = split.delegate as? NSSplitViewController,
              let sidebar = controller.splitViewItems.first
        else { return }
        sidebar.isCollapsed = collapsed
    }

    private static func splitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let found = splitView(in: child) { return found }
        }
        return nil
    }

    /// The main window, once SwiftUI has actually created it. It does not exist at the moment the
    /// scene's `task` first runs, so this waits rather than guessing at a delay.
    private static func settledWindow() async -> NSWindow? {
        for _ in 0..<40 {
            // Width, because the menu bar extra owns a window too and it is a sliver.
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) {
                return window
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Printed rather than logged: the script launches the binary directly and reads its output,
    /// so there is no need for the `log show` dance `--selftest` has to do.
    private static func report(_ line: String) {
        print(line)
        fflush(stdout)
    }

    // MARK: - Demo data

    /// A plausible week of use. Invented, and it has to be — the pictures go in a public README,
    /// and the alternative is publishing whatever the person running the script happened to say.
    private static func seed(_ appState: AppState) {
        appState.settings.settings.appearance.theme = requestedTheme
        requestedTheme.apply()

        // Chosen, so the Modes screen opens on it. Nothing is loaded or fetched by this:
        // `AppState.prepareAssistantIfChosen` stands down in a screenshot run.
        if requestedRawValue == "modes.assistant" {
            appState.settings.settings.refinement.activeModeID = Mode.ask.id
        }

        appState.permissions.poseAsGranted()
        appState.dictation.poseAsArmed()

        appState.vocabulary.add(term: "Kruhlov", soundsLike: ["Kruglov", "Krug love"])
        appState.vocabulary.add(term: "Parakeet", soundsLike: ["para keet", "parrakeet"])
        appState.vocabulary.add(term: "Soniox", soundsLike: ["sonics", "sonyx"])
        appState.vocabulary.add(term: "OurWhisper", soundsLike: ["our whisper", "hour whisper"])

        for entry in demoHistory {
            appState.history.record(entry, settings: HistorySettings())
        }
    }

    private static var demoHistory: [HistoryEntry] {
        let now = Date()
        return [
            HistoryEntry(
                date: now.addingTimeInterval(-9 * 3600),
                rawText: "um can you take a look at the pull request when you get a chance",
                finalText: "Can you take a look at the pull request when you get a chance?",
                appName: "Slack",
                appBundleID: "com.tinyspeck.slackmacgap",
                modeName: "Chat",
                providerID: .parakeet,
                language: .english,
                usedModel: true,
                audioDuration: 4.2,
                processingTime: 0.31
            ),
            HistoryEntry(
                date: now.addingTimeInterval(-5 * 3600),
                rawText: "fix the uh word boundary regex so it stops eating cyrillic",
                finalText: "Fix the word boundary regex so it stops eating Cyrillic.",
                appName: "Xcode",
                appBundleID: "com.apple.dt.Xcode",
                modeName: "Code",
                providerID: .parakeet,
                language: .english,
                usedModel: false,
                audioDuration: 3.6,
                processingTime: 0.24
            ),
            HistoryEntry(
                date: now.addingTimeInterval(-3 * 3600),
                rawText: "привіт як справи я передзвоню тобі за годину",
                finalText: "Привіт, як справи? Я передзвоню тобі за годину.",
                appName: "Telegram",
                appBundleID: "ru.keepcoder.Telegram",
                modeName: "Chat",
                providerID: .parakeet,
                language: .ukrainian,
                usedModel: true,
                audioDuration: 5.1,
                processingTime: 0.42
            ),
            HistoryEntry(
                date: now.addingTimeInterval(-2 * 3600),
                rawText: "thanks for the notes I'll send the revised draft on tuesday no wednesday",
                finalText: "Thanks for the notes. I'll send the revised draft on Wednesday.",
                appName: "Mail",
                appBundleID: "com.apple.mail",
                modeName: "Email",
                providerID: .parakeet,
                language: .english,
                usedModel: true,
                audioDuration: 6.8,
                processingTime: 0.51
            ),
            HistoryEntry(
                date: now.addingTimeInterval(-40 * 60),
                rawText: "add a retention setting that actually deletes the old entries",
                finalText: "Add a retention setting that actually deletes the old entries.",
                appName: "Notes",
                appBundleID: "com.apple.Notes",
                modeName: "General",
                providerID: .parakeet,
                language: .english,
                usedModel: false,
                audioDuration: 3.9,
                processingTime: 0.28
            ),
            HistoryEntry(
                date: now.addingTimeInterval(-12 * 60),
                rawText: "the model download is six hundred megabytes and it only happens once",
                finalText: "The model download is 600 MB, and it only happens once.",
                appName: "Slack",
                appBundleID: "com.tinyspeck.slackmacgap",
                modeName: "Chat",
                providerID: .parakeet,
                language: .english,
                usedModel: true,
                audioDuration: 4.4,
                processingTime: 0.33
            ),
        ]
    }
}
