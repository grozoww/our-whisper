import Foundation

/// Everything the user can change, in one `Codable` value.
///
/// One struct rather than a scattering of `UserDefaults` keys, for two reasons. It is the whole
/// user-visible state of the app, so it can be shown, diffed, backed up and reset as a unit. And
/// `schemaVersion` gives migrations somewhere to hook in, which a defaults dictionary never does
/// until the day you need it and it is too late.
///
/// Nothing secret lives here. API keys go to the Keychain — see `KeychainStore`.
struct Settings: Codable, Equatable, Sendable {
    /// Bumped only when a change cannot be expressed as "a new field with a default".
    var schemaVersion: Int = 1

    var dictation = DictationSettings()
    var refinement = RefinementSettings()
    var sound = SoundSettings()
    var history = HistorySettings()
    var appearance = AppearanceSettings()
    var updates = UpdateSettings()

    init() {}

    /// Unknown keys are ignored and missing keys take their default, so a file written by any
    /// other version of the app loads. See `LenientDecoding.swift` for why this cannot be left to
    /// the synthesized initialiser.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        schemaVersion = container.value(.schemaVersion, or: defaults.schemaVersion)
        dictation = container.value(.dictation, or: defaults.dictation)
        refinement = container.value(.refinement, or: defaults.refinement)
        sound = container.value(.sound, or: defaults.sound)
        history = container.value(.history, or: defaults.history)
        appearance = container.value(.appearance, or: defaults.appearance)
        updates = container.value(.updates, or: defaults.updates)
    }
}

struct DictationSettings: Codable, Equatable, Sendable {
    var language: SpeechLanguage = .auto
    /// Which engine to use when the language allows a choice. Cloud-only languages override this.
    var provider: TranscriptionProviderID = .parakeet
    /// Fall back to the cloud engine when the chosen language is one Parakeet cannot handle,
    /// instead of failing. Off by default: sending audio off the machine is never implicit.
    var allowCloudFallback: Bool = false
    var hotkeyMode: HotkeyMode = .toggle
    var toggleChord: HotkeyChord = .hyper
    /// Defaults to fn: it sits under your thumb, collides with nothing, and holding it has no
    /// meaning of its own. Bound alongside the toggle chord, so both work at once.
    var pushToTalkChord: HotkeyChord? = .fn
    /// How long a modifier-only hold key has to be down before recording starts, in seconds.
    ///
    /// fn is the default hold key and macOS also claims a *tap* of it — switching input source,
    /// opening the emoji picker — so a tap has to mean nothing to us or the two gestures fight
    /// over the same key. A tap is over in well under a second; a hold is not. Zero starts
    /// immediately. Only modifier-only keys wait: a bound key combination is swallowed anyway,
    /// so nothing is competing for it and a delay would be pure lag.
    var pushToTalkHoldDelay: Double = 1.0
    /// Soniox model id. Configurable so a provider-side rename does not need an app release.
    var sonioxModel: String = "stt-async-preview"
    /// Leave the transcript on the clipboard when the app you were in had nothing to paste into.
    ///
    /// On by default, because off is how the app loses what you just said: the ⌘V arrives at an
    /// app with no caret, and `TextInjector.clipboardRestoreDelay` later the clipboard you had
    /// before comes back over the top of it. See `TextInjector.acceptance`.
    var keepOnClipboardWhenNothingFocused: Bool = true
}

struct RefinementSettings: Codable, Equatable, Sendable {
    /// Master switch. Off means the raw transcript is pasted exactly as the model produced it.
    var isEnabled: Bool = true
    /// Use Gemma 4, on this Mac, for the parts rules cannot do — tone, rewriting, judgement.
    /// Rules still run either way; the model is an extra pass, not a replacement.
    ///
    /// On by default, so the app downloads it once at launch the way it downloads the speech model.
    ///
    /// This is a new key and not the old `useOnDeviceModel`, on purpose. That one switched Apple's
    /// model, was off by default because most Macs could not run it, and every settings file the
    /// app has ever written carries its `false`. Reading it here would leave every existing user
    /// without the model this key exists to give them, for a choice they never made about it.
    var useCleanupModel: Bool = true
    var activeModeID: UUID?
    /// Switch modes based on the app being typed into.
    var autoSwitchByApp: Bool = true
    /// Give up on the model and paste the rule-cleaned text rather than making the user wait.
    var modelTimeoutSeconds: Double = 8

    /// Whether the app should have the cleanup model on this Mac: both switches, because the master
    /// one turns it off as surely as its own does. Not stored — it is the two above, read together.
    var wantsCleanupModel: Bool { isEnabled && useCleanupModel }
}

struct SoundSettings: Codable, Equatable, Sendable {
    /// CoreAudio device UID, not name — names are not unique and change with the port label.
    /// `nil` means "follow the system default input", which is what most people want.
    var inputDeviceUID: String?
    var playFeedbackSounds: Bool = true
    var startSound: FeedbackSound = .pop
    var stopSound: FeedbackSound = .tink
    var errorSound: FeedbackSound = .basso
    /// 0...1, applied to the feedback sounds only. Never touches system volume.
    var feedbackVolume: Double = 0.6
}

struct HistorySettings: Codable, Equatable, Sendable {
    var isEnabled: Bool = true
    var retention: HistoryRetention = .days30
    /// Keeping audio makes it possible to re-run a bad transcript against a better model. It also
    /// means recordings of your voice sit on disk, so it is off unless asked for.
    var keepAudio: Bool = false
}

struct AppearanceSettings: Codable, Equatable, Sendable {
    var theme: Theme = .system
    var accent: AccentTint = .orange
    /// Hide the pill entirely for people who find it distracting. The menu bar glyph still moves.
    var showPill: Bool = true
    /// Off by default: this is a menu bar app, and a Dock icon for something you drive entirely
    /// with a hotkey is clutter. On for people who want to find it the ordinary way.
    var showInDock: Bool = false
}

struct UpdateSettings: Codable, Equatable, Sendable {
    /// The single network call the app makes on its own, at launch and then every
    /// `UpdateSchedule.interval`. Off means updates are checked only when the user presses the
    /// button — see `UpdateChecker` for why this is not telemetry.
    var checkAutomatically: Bool = true
    var lastCheck: Date?
    /// A version the user chose to skip, so the banner does not come back every launch.
    var skippedVersion: String?
}

// MARK: - Lenient decoding

extension DictationSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DictationSettings()
        language = container.value(.language, or: defaults.language)
        provider = container.value(.provider, or: defaults.provider)
        allowCloudFallback = container.value(.allowCloudFallback, or: defaults.allowCloudFallback)
        hotkeyMode = container.value(.hotkeyMode, or: defaults.hotkeyMode)
        toggleChord = container.value(.toggleChord, or: defaults.toggleChord)
        pushToTalkChord = container.optional(.pushToTalkChord, defaultWhenAbsent: defaults.pushToTalkChord)
        pushToTalkHoldDelay = container.value(.pushToTalkHoldDelay, or: defaults.pushToTalkHoldDelay)
        sonioxModel = container.value(.sonioxModel, or: defaults.sonioxModel)
        keepOnClipboardWhenNothingFocused = container.value(
            .keepOnClipboardWhenNothingFocused,
            or: defaults.keepOnClipboardWhenNothingFocused
        )
    }
}

extension RefinementSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RefinementSettings()
        isEnabled = container.value(.isEnabled, or: defaults.isEnabled)
        useCleanupModel = container.value(.useCleanupModel, or: defaults.useCleanupModel)
        activeModeID = container.optional(.activeModeID)
        autoSwitchByApp = container.value(.autoSwitchByApp, or: defaults.autoSwitchByApp)
        modelTimeoutSeconds = container.value(.modelTimeoutSeconds, or: defaults.modelTimeoutSeconds)
    }
}

extension SoundSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SoundSettings()
        inputDeviceUID = container.optional(.inputDeviceUID)
        playFeedbackSounds = container.value(.playFeedbackSounds, or: defaults.playFeedbackSounds)
        startSound = container.value(.startSound, or: defaults.startSound)
        stopSound = container.value(.stopSound, or: defaults.stopSound)
        errorSound = container.value(.errorSound, or: defaults.errorSound)
        feedbackVolume = container.value(.feedbackVolume, or: defaults.feedbackVolume)
    }
}

extension HistorySettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HistorySettings()
        isEnabled = container.value(.isEnabled, or: defaults.isEnabled)
        retention = container.value(.retention, or: defaults.retention)
        keepAudio = container.value(.keepAudio, or: defaults.keepAudio)
    }
}

extension AppearanceSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppearanceSettings()
        theme = container.value(.theme, or: defaults.theme)
        accent = container.value(.accent, or: defaults.accent)
        showPill = container.value(.showPill, or: defaults.showPill)
        showInDock = container.value(.showInDock, or: defaults.showInDock)
    }
}

extension UpdateSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UpdateSettings()
        checkAutomatically = container.value(.checkAutomatically, or: defaults.checkAutomatically)
        lastCheck = container.optional(.lastCheck)
        skippedVersion = container.optional(.skippedVersion)
    }
}
