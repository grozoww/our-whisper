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
        case answering
        case failed(String)

        /// A waiting update only replaces the *idle* glyph. Once the app is listening or working,
        /// that is what the user needs to see, and an update will still be there afterwards.
        func menuBarGlyph(updateAvailable: Bool) -> MenuBarGlyph {
            switch self {
            case .idle: .asset(updateAvailable ? MenuBarGlyph.frogWithUpdate : MenuBarGlyph.frog)
            case .listening: .symbol("mic.fill")
            case .transcribing: .symbol("waveform")
            case .formatting: .symbol("sparkles")
            case .answering: .symbol("wand.and.stars")
            case .failed: .symbol("exclamationmark.triangle.fill")
            }
        }

        func accessibilityLabel(updateAvailable: Bool) -> String {
            switch self {
            case .idle: updateAvailable ? "OurWhisper, update available" : "OurWhisper, idle"
            case .listening: "OurWhisper, listening"
            case .transcribing: "OurWhisper, transcribing"
            case .formatting: "OurWhisper, formatting"
            case .answering: "OurWhisper, answering"
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
    /// The assistant modes' model: a larger file than cleanup's, loaded when an assistant mode is
    /// chosen and freed when it has gone unused for a while. See `watchAssistantModel`.
    let assistantModel: OnDeviceRefiner
    let router: TranscriptionRouter
    let speechModel: SpeechModelStatus
    let models: ModelLibrary
    let dictation: DictationController

    /// Mirrors `dictation.phase` for the menu bar and the sidebar, which do not need to know about
    /// the controller's extra states.
    var recordingState: RecordingState {
        switch dictation.phase {
        case .idle: .idle
        case .listening: .listening
        case .transcribing: .transcribing
        case .formatting: .formatting
        case .answering: .answering
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
    private var updateWatcher: Task<Void, Never>?
    private var assistantWatcher: Task<Void, Never>?
    private var didStart = false

    /// - Parameter directory: Where the stores keep their JSON. Injected only so tests can render
    ///   the real screens against real stores without touching the user's data.
    /// - Parameter speechModel: Likewise, so a test can render a screen in the middle of a
    ///   download or a compile without waiting for one.
    /// - Parameter cleanupModel: Likewise, for the cleanup model's download and load.
    /// - Parameter assistantModel: Likewise, for the assistant's.
    init(
        directory: URL = AppDirectories.support,
        speechModel: SpeechModelStatus = SpeechModelStatus(),
        cleanupModel: OnDeviceRefiner = OnDeviceRefiner(),
        assistantModel: OnDeviceRefiner = OnDeviceRefiner(model: .gemma4E4B, slot: .assistant)
    ) {
        let router = TranscriptionRouter()
        let settings = SettingsStore(directory: directory)
        let modes = ModeStore(directory: directory)
        let vocabulary = VocabularyStore(directory: directory)
        let history = HistoryStore(directory: directory)
        let onDevice = cleanupModel

        self.settings = settings
        self.modes = modes
        self.vocabulary = vocabulary
        self.history = history
        self.onDeviceRefiner = onDevice
        self.assistantModel = assistantModel
        self.router = router
        self.speechModel = speechModel
        self.models = ModelLibrary(
            parakeet: router.parakeet,
            speechModel: speechModel,
            cleanup: onDevice,
            assistant: assistantModel
        )
        self.dictation = DictationController(
            settings: settings,
            modes: modes,
            vocabulary: vocabulary,
            history: history,
            router: router,
            refinement: RefinementPipeline(onDevice: onDevice, assistant: assistantModel),
            speechModel: speechModel
        )

        // The library keeps what is on disk as stored state, so it has to be told when the speech
        // model's files have just arrived — and when the user's choice about the cleanup model is
        // made on its screen rather than in Configuration.
        speechModel.onFinish = { [weak self] in self?.models.refresh() }
        models.setCleanupModelEnabled = { [weak self] isOn in
            self?.settings.settings.refinement.useCleanupModel = isOn
        }

        // Choosing an assistant mode — from the menu bar or from Configuration — is what brings its
        // model onto this Mac and into memory. Set up here because both screens write the same
        // setting and neither should have to know.
        settings.onChange = { [weak self] old, new in
            guard old.refinement.activeModeID != new.refinement.activeModeID else { return }
            self?.prepareAssistantIfChosen()
        }

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

        // The cleanup model is downloaded and loaded at launch too, so the first dictation does not
        // wait on a 2.8 GB read — or, on a new install, on the download. After the speech model,
        // not beside it: dictation works without cleanup and not without speech, so on a first
        // launch the 600 MB that matters should not be queueing behind 2.8 GB that does not yet.
        if settings.settings.refinement.wantsCleanupModel, SelfTest.requestedAssistant == nil {
            Task {
                await dictation.launchPreparation?.value
                // Asked again: the speech model can take minutes on a first launch, and someone who
                // reads "2.8 GB" in that time and switches the model off must not have it fetched
                // anyway when the wait ends. Their switch had nothing to cancel yet.
                guard settings.settings.refinement.wantsCleanupModel else { return }
                await onDeviceRefiner.prepare()
                // Only for someone who has the clipboard switched on somewhere: the lookup's
                // context is memory nobody else should be holding. Everyone else who turns it on
                // later is covered by the warm-up when recording starts.
                if modes.anyModePastesClipboard {
                    await onDeviceRefiner.warmUpClipboardLookup()
                }
            }
        }
        // The assistant's model is *loaded* at launch when the chosen mode is an assistant and the
        // file is already here, so the first answer does not wait on a read. It is never fetched
        // at launch: someone who removed it in Models and kept the mode has not asked for 4.6 GB
        // every time the app starts.
        if SelfTest.requestedAssistant == nil,
           modes.activeAssistant(settings: settings.settings.refinement) != nil,
           assistantModel.availability == .downloaded {
            Task { await assistantModel.prepare() }
        }
        watchAssistantModel()

        if let text = SelfTest.requestedCleanup {
            await SelfTest.runCleanup(
                text,
                refiner: SelfTest.refiner(replacing: onDeviceRefiner, slot: .cleanup),
                modes: modes,
                settings: settings.settings.refinement
            )
        }
        if let cases = SelfTest.requestedAssistant {
            await SelfTest.runAssistant(casesPath: cases, refiner: SelfTest.refiner(replacing: assistantModel, slot: .assistant))
        }

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
        watchForUpdates()

        // Only a human sets this, and only to find out whether the updater works on this Mac.
        if SelfTest.installsUpdate {
            await SelfTest.installUpdate(found: updates, with: installer)
        }
    }

    /// Downloads the assistant's model if it is missing and loads it, when the chosen mode is an
    /// assistant. Called when a mode is chosen and when a mode becomes one.
    ///
    /// This is the one place a 4.6 GB download starts without a button on the Models screen being
    /// pressed, and it is a direct result of the person choosing the mode: the mode's own editor and
    /// the Models screen both show it happening, and Remove there takes the file away without this
    /// fetching it again — nothing re-downloads at launch, see `start`. Not under test: the suite
    /// builds an `AppState` and changes the chosen mode, and a test run must not fetch 4.6 GB. Nor
    /// a screenshot run, which poses the assistant's screen by choosing it.
    func prepareAssistantIfChosen() {
        guard !Self.isRunningTests, !ScreenshotMode.isActive,
              modes.activeAssistant(settings: settings.settings.refinement) != nil
        else { return }
        Task { await assistantModel.prepare() }
    }

    /// Frees the assistant's model after it has gone unused for a while. A model of 4.6 GB that is
    /// resident all day for a feature used a few times is memory the rest of the Mac could have,
    /// and bringing it back is seconds, started when recording begins. The cleanup model is never
    /// freed this way: dictation is the app.
    private func watchAssistantModel() {
        guard assistantWatcher == nil else { return }
        assistantWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await self.assistantModel.unloadIfIdle(for: Self.assistantIdleTimeout)
            }
        }
    }

    static let assistantIdleTimeout = Duration.seconds(15 * 60)

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

    /// Asks again every `UpdateSchedule.interval`, for as long as the process lives.
    ///
    /// The loop is never cancelled and reads the switch each time it wakes, instead of being
    /// stopped and started with it. Cancelling mid-request makes `URLSession` throw, and `check`
    /// would record that as a failed check the user then reads in Configuration. A switch that is
    /// off costs one comparison a day; turning it on is `checkForUpdate` from the view.
    ///
    /// A release already on offer is left alone. Re-checking would replace it with a newer one
    /// under a download that is halfway through the old one, and the check after the restart finds
    /// anything newer anyway.
    private func watchForUpdates() {
        guard updateWatcher == nil else { return }
        // After a failed launch check this is the short retry, not a whole interval of silence.
        let firstDelay = UpdateSchedule.delay(after: updates.state)
        updateWatcher = Task { [weak self] in
            var delay = firstDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self else { return }
                if self.settings.settings.updates.checkAutomatically, self.availableUpdate == nil {
                    await self.checkForUpdate()
                }
                delay = UpdateSchedule.delay(after: self.updates.state)
            }
        }
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
