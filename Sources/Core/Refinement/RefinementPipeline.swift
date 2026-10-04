import Foundation
import OSLog

/// Turns a raw transcript into the text that actually gets pasted.
///
/// Two stages, in this order and never the other way round: rules first, model second. Rules are
/// free and certain, so they run even when the model will run too — and if the model is off,
/// unavailable, slow, or produces nonsense, what is already in hand is a cleaned transcript rather
/// than a raw one.
@MainActor
final class RefinementPipeline {
    struct Result: Sendable {
        var text: String
        /// True when the on-device model contributed. Surfaced in History so a surprising result
        /// can be traced to the stage that produced it.
        var usedModel: Bool
    }

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "refine")
    private let onDevice: OnDeviceRefiner

    init(onDevice: OnDeviceRefiner) {
        self.onDevice = onDevice
    }

    /// `clipboard` is what the user had copied when they started speaking, or nil when nothing
    /// read it. Whether the model is shown it at all is the mode's decision, made here so there is
    /// one place to look for the answer to "why did the model see my clipboard". Pasting it is a
    /// different toggle and happens after this, in `DictationController` — the model is never
    /// shown the text it is about to paste verbatim.
    func refine(
        _ raw: String,
        mode: Mode,
        settings: RefinementSettings,
        vocabulary: [VocabularyEntry],
        language: SpeechLanguage,
        clipboard: String? = nil
    ) async -> Result {
        guard settings.isEnabled else { return Result(text: raw, usedModel: false) }

        let rules = RuleRefiner(options: mode.cleanup, vocabulary: vocabulary, language: language)
        let cleaned = rules.refine(raw)

        guard willUseModel(settings, mode: mode) else { return Result(text: cleaned, usedModel: false) }

        let refined = await onDevice.refine(
            cleaned,
            instructions: mode.instructions,
            context: mode.usesClipboardContext ? clipboard.map(ClipboardContext.reference) : nil,
            placeClipboard: Self.shouldPlaceClipboard(mode: mode, clipboard: clipboard),
            timeout: .seconds(max(1, settings.modelTimeoutSeconds))
        )

        guard let refined else { return Result(text: cleaned, usedModel: false) }

        // Vocabulary is re-applied after the model. A rewrite can undo a substitution by restating
        // the name in the model's preferred spelling, and the vocabulary list is the user telling
        // us, explicitly, which spelling wins.
        let final = mode.cleanup.applyVocabulary
            ? RuleRefiner(
                options: CleanupOptions.none.applyingVocabularyOnly(),
                vocabulary: vocabulary,
                language: language
            ).refine(refined)
            : refined

        log.debug("Refined with the on-device model")
        return Result(text: final, usedModel: true)
    }

    /// Whether the on-device model can run at all: switched on, and available on this Mac.
    ///
    /// Both clipboard features are downstream of this. Context is shown to the model, and the
    /// paste only ever lands where the model marked — so with the model off there is nothing
    /// either of them could do, and `DictationController` does not read the clipboard at all
    /// rather than reading it and finding no use for it.
    func modelIsEnabled(_ settings: RefinementSettings) -> Bool {
        Self.modelIsEnabled(
            isEnabled: settings.isEnabled,
            useCleanupModel: settings.useCleanupModel,
            modelIsAvailable: onDevice.availability.isAvailable
        )
    }

    /// The same question for one dictation. A mode with no instructions skips the model — Raw is
    /// the shipped example — and skips the clipboard with it.
    func willUseModel(_ settings: RefinementSettings, mode: Mode) -> Bool {
        Self.willUseModel(
            isEnabled: settings.isEnabled,
            useCleanupModel: settings.useCleanupModel,
            modelIsAvailable: onDevice.availability.isAvailable,
            instructions: mode.instructions
        )
    }

    /// The two above, as the arithmetic without the dependency.
    ///
    /// Pure because the instance versions read `onDevice.availability`, which a test cannot set —
    /// and a CI runner never has the model downloaded, so every assertion against them passes for
    /// the wrong reason. This is the decision that keeps the app off the user's pasteboard; it has to
    /// be assertable on a machine that does not have the model.
    nonisolated static func modelIsEnabled(
        isEnabled: Bool,
        useCleanupModel: Bool,
        modelIsAvailable: Bool
    ) -> Bool {
        isEnabled && useCleanupModel && modelIsAvailable
    }

    nonisolated static func willUseModel(
        isEnabled: Bool,
        useCleanupModel: Bool,
        modelIsAvailable: Bool,
        instructions: String
    ) -> Bool {
        modelIsEnabled(
            isEnabled: isEnabled,
            useCleanupModel: useCleanupModel,
            modelIsAvailable: modelIsAvailable
        ) && !instructions.isEmpty
    }

    /// Whether to ask the model where the clipboard goes. There is nothing to weigh: if the mode
    /// pastes the clipboard and there is one, the model is asked.
    ///
    /// There used to be a word list here — the transcript had to contain "clipboard", "буфер" and
    /// so on before the request went in the prompt, on the argument that the model should decide
    /// *where* and never *whether*. That argument stopped holding once a missing marker meant the
    /// clipboard was not pasted at all: a list of nouns then decides, silently, that "paste what I
    /// copied" is not a request, and the user's clipboard never arrives. A list can only be wrong
    /// in that direction, and the prompt already tells the model to write nothing when the
    /// sentence was not asking. The whether is the model's too.
    nonisolated static func shouldPlaceClipboard(mode: Mode, clipboard: String?) -> Bool {
        mode.pastesClipboard && !(clipboard ?? "").isEmpty
    }
}

private extension CleanupOptions {
    func applyingVocabularyOnly() -> CleanupOptions {
        var options = self
        options.applyVocabulary = true
        return options
    }
}
