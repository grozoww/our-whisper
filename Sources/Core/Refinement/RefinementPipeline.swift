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

    /// The assistant modes' model, a different file from cleanup's. Nil only where nothing needs
    /// it — most of the tests — and then an assistant mode has no answer to give.
    let assistant: OnDeviceRefiner?

    init(onDevice: OnDeviceRefiner, assistant: OnDeviceRefiner? = nil) {
        self.onDevice = onDevice
        self.assistant = assistant
    }

    /// `clipboard` is what the user had copied when they started speaking, or nil when nothing
    /// read it. Whether the cleanup model is shown it is the mode's decision, made here so there
    /// is one place to look for the answer to "why did the model see my clipboard". Pasting it is
    /// a different toggle and happens after this, in `DictationController` — the model is never
    /// shown the text it is about to paste verbatim.
    ///
    /// Where the clipboard goes is settled before cleanup, not by it. The lookup reads the sentence
    /// and quotes the words that ask for the clipboard; they become a marker; cleanup then runs on
    /// a sentence that already has the marker in it and has only to leave it alone. The other
    /// order — one prompt that cleans *and* places — was measured against Gemma 4 E2B and wrote no
    /// marker for any of eight phrasings, see `OnDeviceRefiner.clipboardRequest`.
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

        let timeout = Duration.seconds(max(1, settings.modelTimeoutSeconds))

        // A quick question with a short answer, so it never gets the whole budget: a lookup that
        // runs long should leave the cleanup its time rather than spend it.
        var marked = cleaned
        if Self.shouldPlaceClipboard(mode: mode, clipboard: clipboard),
           let request = await onDevice.clipboardRequest(in: cleaned, timeout: min(timeout, .seconds(4))) {
            marked = ClipboardContext.marking(request, in: cleaned)
        }
        let placed = marked != cleaned

        // A sentence that was only the request is now only the marker, and there is nothing in it
        // to clean. Asking anyway got the answer thrown away as implausible every time.
        if marked == ClipboardContext.marker { return Result(text: marked, usedModel: true) }

        let refined = await onDevice.refine(
            marked,
            instructions: mode.instructions,
            context: mode.usesClipboardContext ? clipboard.map(ClipboardContext.reference) : nil,
            timeout: timeout
        )

        // The marker is the only thing that knows where the clipboard goes, so a cleanup that lost
        // it has lost the paste. That answer is thrown away like any other implausible one, and
        // the rule-cleaned sentence — marker included — is what goes on.
        guard let refined, !placed || ClipboardContext.hasMarker(refined) else {
            return Result(text: marked, usedModel: placed)
        }

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

    /// What an assistant mode makes of one dictation.
    struct AssistantResult: Equatable, Sendable {
        var text: String
        /// The clipboard was longer than `ClipboardContext.materialLimit` and the model read the
        /// first part of it.
        var materialWasCut: Bool
        /// The answer ran into its token limit and stops early.
        var answerWasCut: Bool
        var stats: LlamaEngine.Stats?
    }

    /// The assistant's version of `refine`: `raw` is a request, `material` is what it is about.
    ///
    /// Rules clean the *request* — fillers, false starts, the vocabulary list, so a name spoken as
    /// it sounds is spelled the way it is written — and nothing touches the answer. In particular
    /// the vocabulary is not applied after the model, which is what `refine` does and is right
    /// there: an assistant's answer restates the material, the material is text somebody else
    /// wrote, and a substitution list rewriting it would change what was copied.
    ///
    /// Throws `OnDeviceRefiner.AnswerFailure`, and `CancellationError` when the person pressed
    /// Escape. Unlike `refine` there is no softer output to fall back on.
    func answer(
        _ raw: String,
        mode: Mode,
        vocabulary: [VocabularyEntry],
        language: SpeechLanguage,
        material: String?,
        sampling: LlamaEngine.Sampling = .assistant
    ) async throws -> AssistantResult {
        guard let assistant else {
            throw OnDeviceRefiner.AnswerFailure.notReady("The assistant model is not set up.")
        }

        let request = RuleRefiner(options: mode.cleanup, vocabulary: vocabulary, language: language).refine(raw)
        guard !request.isEmpty else { throw OnDeviceRefiner.AnswerFailure.emptyRequest }

        let capped = material.map(ClipboardContext.material)
        let answer = try await assistant.answer(
            to: request,
            material: capped?.text,
            materialWasCut: capped?.wasCut ?? false,
            instructions: mode.instructions,
            thinks: mode.thinks,
            sampling: sampling
        )
        return AssistantResult(
            text: answer.text,
            materialWasCut: capped?.wasCut ?? false,
            answerWasCut: answer.wasCut,
            stats: answer.stats
        )
    }

    /// Whether an assistant mode could answer without a download: the model is on this Mac, loaded
    /// or loadable. Decides whether the clipboard is read at all, like `modelIsEnabled` does for
    /// dictation — reading it for a feature that cannot run would be touching it for nothing.
    var assistantMayRun: Bool {
        guard let assistant else { return false }
        return Self.mayRun(assistant.availability)
    }

    nonisolated static func mayRun(_ availability: OnDeviceRefiner.Availability) -> Bool {
        switch availability.assistantGate {
        case .ready, .loadFirst: true
        case .blocked: false
        }
    }

    var assistantGate: OnDeviceRefiner.Availability.AssistantGate {
        assistant?.availability.assistantGate ?? .blocked("The assistant model is not set up.")
    }

    /// Reads the assistant's model back into memory if it was freed, and does nothing otherwise.
    /// Never downloads: a file that is not there is `blocked`, and a 4.6 GB fetch is not something
    /// to start from a hotkey press.
    func warmUpAssistant() async {
        guard let assistant, assistant.availability.assistantGate == .loadFirst else { return }
        await assistant.prepare()
    }

    /// Gets the clipboard lookup ready. See `OnDeviceRefiner.warmUpClipboardLookup`.
    func warmUpClipboardLookup() async {
        await onDevice.warmUpClipboardLookup()
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

    /// Whether to look for a request for the clipboard at all. There is nothing to weigh: if the
    /// mode pastes the clipboard and there is one, the model is asked.
    ///
    /// There used to be a word list here — the transcript had to contain "clipboard", "буфер" and
    /// so on before the request was looked for, on the argument that the model should decide
    /// *where* and never *whether*. That argument stopped holding once a missing marker meant the
    /// clipboard was not pasted at all: a list of nouns then decides, silently, that "paste what I
    /// copied" is not a request, and the user's clipboard never arrives. A list can only be wrong
    /// in that direction. The lookup says NONE for a sentence that was not asking.
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
