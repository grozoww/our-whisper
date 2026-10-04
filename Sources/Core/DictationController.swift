import AppKit
import OSLog

/// Drives one dictation: hotkey down, record, transcribe, clean up, paste, remember.
///
/// Everything here is ordered around one rule — the user's focused text field must survive the
/// whole cycle. That is why the target is captured before any UI appears and why the pill is a
/// non-activating panel.
///
/// The stages after transcription are all optional and all fail soft. Cleanup that cannot run
/// pastes the raw transcript; history that cannot be written loses a record, not the paste. The
/// text reaching the field is the only thing that is allowed to fail loudly.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case formatting
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Surfaced on the Home screen so a missing permission is explained rather than just broken.
    private(set) var hotkeyArmed = false

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "dictation")

    private let capture = AudioCapture()
    private let hotkeys = HotkeyMonitor()
    private let injector = TextInjector()
    private let pill = PillWindowController()
    private let sounds = SoundPlayer()

    private let settings: SettingsStore
    private let modes: ModeStore
    private let vocabulary: VocabularyStore
    private let history: HistoryStore
    private let router: TranscriptionRouter
    private let refinement: RefinementPipeline

    /// What the speech model is doing, which is not the same question as what a dictation is
    /// doing — see `SpeechModelStatus` for why the two used to share a phase and what it cost.
    let speechModel: SpeechModelStatus

    /// The speech model's preparation at launch, so whatever should wait for it can.
    private(set) var launchPreparation: Task<Void, Never>?

    private var levelTask: Task<Void, Never>?
    private var isRecording = false

    /// What was on the clipboard when this dictation started. Held only until the text is pasted.
    private var clipboardContext: String?

    init(
        settings: SettingsStore,
        modes: ModeStore,
        vocabulary: VocabularyStore,
        history: HistoryStore,
        router: TranscriptionRouter,
        refinement: RefinementPipeline,
        speechModel: SpeechModelStatus = SpeechModelStatus()
    ) {
        self.settings = settings
        self.modes = modes
        self.vocabulary = vocabulary
        self.history = history
        self.router = router
        self.refinement = refinement
        self.speechModel = speechModel
    }

    /// The engine the Home screen and Models library talk about. Exposed because the download it
    /// owns is the app's largest, and two screens need to show its state.
    var speechProvider: ParakeetProvider { router.parakeet }

    // MARK: - Lifecycle

    func start() {
        applySettings()
        hotkeys.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .toggle: self.toggle()
            case .pressStart: self.beginRecording()
            case .pressEnd: self.finishRecording()
            case .cancel: self.cancel()
            }
        }
        armHotkeys()

        // Load the model now rather than on the first hotkey press. A 600 MB download the first
        // time you try to dictate would feel like the app is broken.
        launchPreparation = Task {
            await prepareModel()
            if let path = SelfTest.requestedPath {
                await SelfTest.run(path: path, language: SelfTest.requestedLanguage, provider: router.parakeet)
            }
        }
    }

    /// Re-reads anything the hotkey layer caches. Called on launch and whenever the shortcut or
    /// its mode changes in Configuration, so a rebind takes effect without a restart.
    func applySettings() {
        let dictation = settings.settings.dictation
        let pushToTalk = dictation.pushToTalkChord.flatMap { $0.isEmpty ? nil : $0 }
        let holdDelay = Duration.milliseconds(Int(dictation.pushToTalkHoldDelay * 1000))

        switch dictation.hotkeyMode {
        case .toggle:
            // Both are live at once. Someone who set a push-to-talk key expects it to work without
            // also having to change a mode picker.
            hotkeys.configure(toggle: dictation.toggleChord, pushToTalk: pushToTalk, holdDelay: holdDelay)
        case .pushToTalk:
            // The main chord holds rather than toggles, so nothing stays bound to toggle.
            hotkeys.configure(
                toggle: nil,
                pushToTalk: pushToTalk ?? dictation.toggleChord,
                holdDelay: holdDelay
            )
        }
    }

    /// Re-arms after the user grants Accessibility, which can happen long after launch.
    func armHotkeys() {
        hotkeyArmed = hotkeys.arm()
    }

    /// Screenshot mode only, alongside `PermissionsManager.poseAsGranted`. No event tap is
    /// installed during a screenshot run, so Home would otherwise be a picture of a warning.
    func poseAsArmed() {
        hotkeyArmed = true
    }

    /// Gets the speech model ready, or says why it could not.
    ///
    /// Nothing here touches `phase`: whether the model is ready is `speechModel`'s to say, and
    /// a dictation's phase is only about the dictation. It used to carry both, and went back to
    /// idle on its own 2.5 seconds after a refused hotkey press — with the model still compiling.
    private func prepareModel() async {
        // Nothing to download when the user runs entirely on the cloud engine, and downloading
        // 600 MB they asked not to use would be rude.
        guard router.plannedProviderID(for: settings.settings.dictation) == .parakeet else { return }

        do {
            try await speechModel.prepare(using: router.parakeet)
            log.info("Speech model ready")
        } catch {
            log.error("Model preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Recording

    func toggle() {
        isRecording ? finishRecording() : beginRecording()
    }

    private func beginRecording() {
        guard !isRecording else { return }

        // The last dictation is still being turned into text, and the pill is saying so. A second
        // one cannot start under it: both share one `TextInjector`, so the old one pasted into
        // whatever app the new one had captured, and when it finished it replaced the new pill
        // with a tick and hid it 0.7 s later, in the middle of the recording. `isRecording` is no
        // help — it goes false the moment recording stops.
        //
        // Nothing here can leave the hotkey dead: every step after recording is bounded (the
        // model has its own timeout, the cloud engine has one, the paste takes milliseconds) and
        // every failure goes through `notify`, which puts the phase back.
        switch phase {
        case .transcribing, .formatting:
            log.info("Hotkey ignored: the last dictation is still being processed")
            return
        default:
            break
        }

        // Asked of the status and not of `phase`. The phase goes back to idle on its own after the
        // first refusal, and the second press then recorded a sentence and failed with a different
        // message, long after the user had stopped being told why.
        let usesSpeechModel = router.plannedProviderID(for: settings.settings.dictation) == .parakeet
        switch SpeechModelStatus.gate(for: speechModel.state, usesSpeechModel: usesSpeechModel) {
        case .proceed:
            break
        case .wait(let message):
            notify(message)
            return
        case .loadFirst(let message):
            log.info("Hotkey pressed with the speech model not loaded; preparing it")
            Task { await prepareModel() }
            notify(message)
            return
        }

        // Fail here rather than after recording. Telling someone their language needs a key they
        // have not added is useful before they speak and infuriating after.
        do {
            _ = try router.provider(for: settings.settings.dictation)
        } catch {
            notify(error.localizedDescription)
            return
        }

        // Before anything is drawn. Showing the pill first would let `frontmostApplication` change
        // under us, and the text would land in the wrong app.
        injector.captureTarget()

        // Read now, for the same reason: this is the clipboard the user had when they started
        // talking, and by the time the text is pasted the injector will have overwritten it.
        //
        // Two conditions, and both have to hold before the pasteboard is touched at all. Some mode
        // has to want it, and the on-device model has to be able to run — every use of the
        // clipboard goes through the model now, so with the model off reading it would be reading
        // it for nothing. Asked of the injector rather than of the pasteboard, because a transcript
        // the last dictation deliberately left there is not something the user copied.
        let modelCanRun = refinement.modelIsEnabled(settings.settings.refinement)
        clipboardContext = modelCanRun && modes.anyModeReadsClipboard ? injector.userClipboard() : nil

        do {
            try capture.start(deviceUID: settings.settings.sound.inputDeviceUID)
        } catch {
            log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            notify(error.localizedDescription)
            return
        }

        isRecording = true
        hotkeys.isRecording = true
        phase = .listening
        playFeedback(settings.settings.sound.startSound)
        showPill(.listening)
        startLevelUpdates()
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        hotkeys.isRecording = false
        stopLevelUpdates()

        let samples = capture.stop()
        phase = .transcribing
        pill.setPhase(.transcribing)
        playFeedback(settings.settings.sound.stopSound)

        Task { await transcribeAndInject(samples) }
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        hotkeys.isRecording = false
        stopLevelUpdates()
        _ = capture.stop()
        clipboardContext = nil
        phase = .idle
        pill.hide()
        log.debug("Recording cancelled")
    }

    private func transcribeAndInject(_ samples: [Float]) async {
        let current = settings.settings
        let clipboard = clipboardContext
        // Nothing below needs it again, and holding a copy of someone's clipboard between
        // dictations is not something to do by accident.
        clipboardContext = nil

        do {
            let provider = try router.provider(for: current.dictation)
            let result = try await provider.transcribe(samples: samples, language: current.dictation.language)
            guard !result.text.isEmpty else {
                notify("Nothing was said")
                return
            }

            log.info("Transcribed \(result.audioDuration, format: .fixed(precision: 1))s in \(result.processingTime, format: .fixed(precision: 2))s (\(result.realtimeFactor, format: .fixed(precision: 0))x realtime)")

            // Before anything reads the target: the mode, the paste and History all need the app
            // that had the keyboard, which is not always the frontmost one.
            await injector.confirmTarget()

            let mode = modes.resolve(
                settings: current.refinement,
                frontmostBundleID: injector.targetBundleID
            )

            // The pill only says "cleaning up" when something slow is actually happening. Rules
            // finish in microseconds, and a flash of a stage nobody waited for reads as jitter.
            let willUseModel = refinement.willUseModel(current.refinement, mode: mode)
            if willUseModel {
                phase = .formatting
                pill.setPhase(.formatting)
            }

            let refined = await refinement.refine(
                result.text,
                mode: mode,
                settings: current.refinement,
                vocabulary: vocabulary.enabledEntries,
                language: current.dictation.language,
                clipboard: clipboard
            )

            // The clipboard goes in after cleanup, never through it: this is text the user copied
            // to paste, and a model that reworded a stack trace would have ruined the point. It
            // lands on the marker the model left, and nowhere else — no marker, nothing pasted.
            //
            // `willUseModel` gates it because the marker is the only thing that knows where the
            // clipboard goes. A dictation the model never touched — Raw mode, or the model
            // switched off — cannot have one, and this saves reaching into `substituted` to find
            // that out.
            let pasted = willUseModel && mode.pastesClipboard
                ? ClipboardContext.substituted(clipboard, into: refined.text)
                : refined.text

            let method = try await injector.inject(
                pasted,
                keepWhenNothingFocused: current.dictation.keepOnClipboardWhenNothingFocused
            )
            log.debug("Injected via \(method.rawValue, privacy: .public)")

            // What is recorded is what was dictated, not what was pasted. History is kept for
            // thirty days by default, and writing a copy of every clipboard used into it would
            // outlive the paste by a month for no benefit the user asked for.
            record(
                raw: result.text,
                // History records what was dictated, and `[[CLIPBOARD]]` is not something anybody
                // said — it is how the position reached the paste. Taken back out here, punctuation
                // and all, so the entry reads as a sentence rather than as an internal token. What
                // the user actually said is still on the entry, in `rawText`.
                final: ClipboardContext.removingMarker(from: refined.text),
                mode: mode,
                transcription: result,
                usedModel: refined.usedModel,
                samples: samples,
                settings: current
            )

            phase = .idle
            if method == .clipboardOnly {
                // A tick and the app name would read as "pasted into Finder", which is the exact
                // thing that did not happen. This one has to be read rather than glanced at, so
                // it stays up longer than a paste the user watched arrive.
                pill.setPhase(.success("Copied to the clipboard"))
                pill.dismiss(after: .milliseconds(1600))
            } else {
                pill.setPhase(.success(injector.targetName ?? "Pasted"))
                pill.dismiss(after: .milliseconds(700))
            }
        } catch {
            log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            notify(error.localizedDescription)
        }
    }

    // MARK: - History

    private func record(
        raw: String,
        final: String,
        mode: Mode,
        transcription: Transcription,
        usedModel: Bool,
        samples: [Float],
        settings current: Settings
    ) {
        guard current.history.isEnabled else { return }

        let audioFileName = current.history.keepAudio ? saveAudio(samples) : nil

        history.record(
            HistoryEntry(
                rawText: raw,
                finalText: final,
                appName: injector.targetName,
                appBundleID: injector.targetBundleID,
                modeName: mode.name,
                providerID: router.plannedProviderID(for: current.dictation),
                language: current.dictation.language,
                usedModel: usedModel,
                audioDuration: transcription.audioDuration,
                processingTime: transcription.processingTime,
                audioFileName: audioFileName
            ),
            settings: current.history
        )
    }

    /// Writes the recording next to its history entry. Failure is logged and ignored: a missing
    /// audio file costs the user a replay, and refusing the whole entry over it would cost them the
    /// transcript too.
    private func saveAudio(_ samples: [Float]) -> String? {
        let name = "\(UUID().uuidString).wav"
        let url = AppDirectories.recordings.appendingPathComponent(name)
        do {
            try WAVEncoder.encode(samples: samples).write(to: url, options: .atomic)
            return name
        } catch {
            log.error("Could not save recording: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Feedback

    private func showPill(_ phase: PillModel.Phase) {
        guard settings.settings.appearance.showPill else { return }
        // The target was captured a moment ago, so this is the app the user is looking at — which
        // is what decides the display the pill goes on.
        pill.show(focusedIn: injector.targetProcessIdentifier)
        pill.setPhase(phase)
    }

    private func playFeedback(_ sound: FeedbackSound) {
        let soundSettings = settings.settings.sound
        guard soundSettings.playFeedbackSounds else { return }
        sounds.play(sound, volume: soundSettings.feedbackVolume)
    }

    private func notify(_ message: String) {
        phase = .failed(message)
        playFeedback(settings.settings.sound.errorSound)
        // `show()` resets the model, so the phase has to be set after it — the other way round
        // and the pill spends its 2.5 seconds showing audio bars instead of the error.
        // Asked of the workspace rather than of the injector: this is reachable before a target
        // has been captured, and the previous dictation's app is not where the user is now.
        pill.show(focusedIn: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        pill.setPhase(.failure(message))
        pill.dismiss(after: .seconds(2.5))
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if case .failed = phase { phase = .idle }
        }
    }

    // MARK: - Level metering

    /// 30 Hz is enough for the bars to look alive and cheap enough not to matter. Reading the
    /// level is a lock and a float copy; no audio work happens on this timer.
    private func startLevelUpdates() {
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pill.pillModel.push(level: self.capture.currentLevel)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopLevelUpdates() {
        levelTask?.cancel()
        levelTask = nil
    }
}
