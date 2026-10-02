import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    /// Where the app is in the record → transcribe → format → paste cycle. Drives the menu bar
    /// glyph and the pill overlay, so every stage the user waits on needs its own case.
    enum RecordingState: Equatable {
        case idle
        case listening
        case transcribing
        case formatting
        case failed(String)

        /// A waiting update only replaces the *idle* glyph. Once the app is listening or working,
        /// that is what the user needs to see, and an update will still be there afterwards.
        func menuBarGlyph(updateAvailable: Bool) -> MenuBarGlyph {
            switch self {
            case .idle: .asset(updateAvailable ? MenuBarGlyph.frogWithUpdate : MenuBarGlyph.frog)
            case .listening: .symbol("mic.fill")
            case .transcribing: .symbol("waveform")
            case .formatting: .symbol("sparkles")
            case .failed: .symbol("exclamationmark.triangle.fill")
            }
        }

        func accessibilityLabel(updateAvailable: Bool) -> String {
            switch self {
            case .idle: updateAvailable ? "OurWhisper, update available" : "OurWhisper, idle"
            case .listening: "OurWhisper, listening"
            case .transcribing: "OurWhisper, transcribing"
            case .formatting: "OurWhisper, formatting"
            case .failed(let message): "OurWhisper, error: \(message)"
            }
        }
    }

    /// What the menu bar draws. Idle is the app's own mark, because that is the state the icon
    /// sits in all day and a generic microphone up there could belong to anything; the busy
    /// states stay SF Symbols, because once the app is doing something, what it is doing matters
    /// more than whose app it is.
    enum MenuBarGlyph: Equatable {
        /// The frog, drawn by `scripts/make-icon.swift` into `Assets.xcassets` as a template
        /// image. A name that does not resolve draws nothing whatsoever — no placeholder, no
        /// warning, just a gap in the menu bar — which is what `AppBundleTests` guards.
        static let frog = "MenuBarIcon"

        /// The frog with a download badge on its chin, drawn by the same script as the frog and
        /// shown in its place while an update is waiting. A second image rather than a badge laid
        /// over the first, because a status item is one template and there is nothing at runtime
        /// to composite onto; and drawn rather than borrowed from SF Symbols so it is still our
        /// frog, which a stock "update" symbol would stop being.
        static let frogWithUpdate = "MenuBarUpdateIcon"

        case asset(String)
        case symbol(String)
    }

    var selectedSection: NavigationSection = .home

    let permissions = PermissionsManager()
    let updates = UpdateChecker()
    let installer = UpdateInstaller()

    let settings: SettingsStore
    let modes: ModeStore
    let vocabulary: VocabularyStore
    let history: HistoryStore
    let onDeviceRefiner: OnDeviceRefiner
    let router: TranscriptionRouter
    let models: ModelLibrary
    let dictation: DictationController

    /// Mirrors `dictation.phase` for the menu bar and the sidebar, which do not need to know about
    /// the controller's extra states.
    var recordingState: RecordingState {
        switch dictation.phase {
        case .idle, .preparingModel: .idle
        case .listening: .listening
        case .transcribing: .transcribing
        case .formatting: .formatting
        case .failed(let message): .failed(message)
        }
    }

    /// The release waiting to be installed, if the last check found one. What the menu bar glyph
    /// and the menu's update item both key on, so they cannot disagree.
    var availableUpdate: UpdateChecker.Release? {
        if case .available(let release) = updates.state { release } else { nil }
    }

    /// Name of the input device shown in the toolbar.
    var inputDeviceName: String {
        guard let uid = settings.settings.sound.inputDeviceUID else { return "Default input" }
        return AudioDevices.inputs().first { $0.id == uid }?.name ?? "Default input"
    }

    private var accessibilityWatcher: Task<Void, Never>?
    private var didStart = false

    /// - Parameter directory: Where the stores keep their JSON. Injected only so tests can render
    ///   the real screens against real stores without touching the user's data.
    init(directory: URL = AppDirectories.support) {
        let router = TranscriptionRouter()
        let settings = SettingsStore(directory: directory)
        let modes = ModeStore(directory: directory)
        let vocabulary = VocabularyStore(directory: directory)
        let history = HistoryStore(directory: directory)
        let onDevice = OnDeviceRefiner()

        self.settings = settings
        self.modes = modes
        self.vocabulary = vocabulary
        self.history = history
        self.onDeviceRefiner = onDevice
        self.router = router
        self.models = ModelLibrary(parakeet: router.parakeet)
        self.dictation = DictationController(
            settings: settings,
            modes: modes,
            vocabulary: vocabulary,
            history: history,
            router: router,
            refinement: RefinementPipeline(onDevice: onDevice)
        )

        // The installer knows how to replace the app but not when doing so would cost the user
        // something, and it has no way to reach the stores. These are the two questions it asks
        // before taking the app away.
        installer.isSafeToRestart = { [weak self] in self?.recordingState == .idle }
        installer.flushBeforeRestart = { [weak self] in self?.flushToDisk() }
    }

    func start() async {
        // The unit tests run against the app bundle as their host, so launching it must not kick
        // off a 600 MB model download or install a system-wide event tap. Nothing in `start()` is
        // under test; the pieces it wires together are tested directly.
        guard !Self.isRunningTests else { return }
        guard !didStart else { return }
        didStart = true

        // Nothing below may run twice over. After an in-app update this process was started by
        // the copy it replaces, which is still shutting down — `open -n` is the only form that
        // launches anything at all while an instance is running, so for a moment there are two.
        // Waiting is what keeps there from being two event taps and two model loads.
        await UpdateInstaller.waitForPredecessor()

        settings.settings.appearance.theme.apply()
        WindowPresenter.setShowsDockIcon(settings.settings.appearance.showInDock)
        // Turning history off stops new entries; it does not destroy old ones. Pruning is always
        // against the retention the user actually chose.
        history.prune(retention: settings.settings.history.retention)
        models.refresh()

        permissions.refresh()
        permissions.beginMonitoring()
        dictation.start()
        watchAccessibility()

        // An accessory app with no Dock icon that silently does nothing is indistinguishable from
        // an app that failed to launch. If it cannot work yet, say so on screen rather than
        // waiting for a hotkey press that cannot possibly be heard.
        if let requested = NavigationSection.requested {
            selectedSection = requested
            WindowPresenter.activate()
        } else if !permissions.allGranted {
            selectedSection = .home
            WindowPresenter.activate()
        }

        if settings.settings.updates.checkAutomatically {
            await checkForUpdate()
        }

        // Only a human sets this, and only to find out whether the updater works on this Mac.
        if SelfTest.installsUpdate {
            await SelfTest.installUpdate(found: updates, with: installer)
        }
    }

    /// Asks GitHub for the newest release, and — when there is one — works out whether this build
    /// can install it.
    ///
    /// The second half is why this is not just `updates.check`. The menu bar's update item needs
    /// `installer.refusal`, which is a round trip to the security daemon the first time it is
    /// asked, and nothing in a SwiftUI body may ask the system a question. The menu can be opened
    /// from any desktop before either window has been, so there is no screen's `.task` to count on:
    /// the answer is read here, once, and the item reads the cached value.
    func checkForUpdate(force: Bool = false) async {
        await updates.check(skippedVersion: settings.settings.updates.skippedVersion, force: force)
        settings.settings.updates.lastCheck = Date()
        if availableUpdate != nil { _ = installer.refusal }
    }

    static var isRunningTests: Bool { AppDirectories.isRunningTests }

    /// Called from the app delegate on the way out, so a setting changed a moment before quitting
    /// is on disk rather than sitting in the coalescing window.
    func flushToDisk() {
        settings.flush()
        modes.flush()
        vocabulary.flush()
        history.flush()
    }

    /// The hotkey tap cannot be installed until Accessibility is granted, and the user usually
    /// grants it minutes after launch. Without this the app would need a restart to work.
    private func watchAccessibility() {
        guard accessibilityWatcher == nil else { return }
        accessibilityWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if self.permissions.accessibility.isGranted, !self.dictation.hotkeyArmed {
                    self.dictation.armHotkeys()
                }
            }
        }
    }
}
