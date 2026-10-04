import Foundation

/// A named way of cleaning up what you said.
///
/// The same sentence wants different treatment depending on where it lands. Dictating a commit
/// message wants the filler gone and nothing else touched; dictating an email wants full
/// sentences and a greeting left alone. A mode is that difference, made explicit and switchable —
/// by hand from the menu bar, or automatically from the app you are typing into.
struct Mode: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var symbol: String
    var tint: ModeColor = .blue

    /// Passed to the on-device model as its system instructions. Ignored when the model is off,
    /// which is why the rule toggles below are not merely a subset of it.
    var instructions: String

    var cleanup: CleanupOptions = CleanupOptions()

    /// Show the on-device model what is on the clipboard, as reference for spelling.
    ///
    /// Per mode rather than global because it is only ever worth the privacy cost in some of
    /// them: dictating a reply wants the message you copied, dictating a password field does not.
    /// Off everywhere by default — reading the clipboard is something the user asks for.
    var usesClipboardContext: Bool = false

    /// Paste what is on the clipboard into the dictated text, verbatim, where you asked for it.
    ///
    /// For handing something you copied to whatever you are dictating into: copy a stack trace,
    /// say what you want done about it, and both arrive in one paste. Separate from
    /// `usesClipboardContext` because they are opposite treatments of the same text — that one
    /// shows it to the model and forbids it from repeating any of it, this one never shows it to
    /// the model at all and reproduces it exactly. Off everywhere by default, for the same reason.
    ///
    /// Where it lands is found by the on-device model, which reads the sentence — never the
    /// clipboard — and says which words asked for it. If it finds none, or does not answer, nothing
    /// is pasted. There is no phrase to configure, because the words are *spoken* and arrive
    /// declined, split or in another language — see `OnDeviceRefiner.clipboardRequest`.
    var pastesClipboard: Bool = false

    /// Bundle identifiers this mode claims. When "switch by app" is on, focusing one of these
    /// selects this mode. Empty means the mode is only ever chosen by hand.
    var appBundleIDs: [String] = []

    /// Built-in modes can be edited but not deleted, and reappear if the file is reset. Marking
    /// them lets the UI say so instead of letting someone delete the last mode and be left with
    /// nothing to dictate into.
    var isBuiltIn: Bool = false

    func claims(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return appBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

/// The deterministic half of cleanup. Each of these is a rule that runs the same way every time,
/// with no model involved — which is what makes them safe to leave on by default.
struct CleanupOptions: Codable, Equatable, Sendable {
    /// "um", "uh", and friends.
    var removeFillers: Bool = true
    /// "send it Tuesday, no, Wednesday" becomes "send it Wednesday".
    var resolveSelfCorrections: Bool = true
    /// Saying "comma" types a comma.
    var spokenPunctuation: Bool = true
    /// Capitalise the first word of each sentence.
    var sentenceCase: Bool = true
    /// Apply the Vocabulary list.
    var applyVocabulary: Bool = true
    /// Squeeze runs of spaces and fix the space that ends up before a comma.
    var tidyWhitespace: Bool = true

    /// Nothing at all — used by the "Raw" mode, and by the master switch when refinement is off.
    static let none = CleanupOptions(
        removeFillers: false,
        resolveSelfCorrections: false,
        spokenPunctuation: false,
        sentenceCase: false,
        applyVocabulary: false,
        tidyWhitespace: false
    )
}

extension Mode {
    /// Shipped modes. Deliberately few: five is a menu, fifteen is a chore.
    static var builtIns: [Mode] {
        [
            Mode(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
                name: "General",
                symbol: "text.bubble",
                tint: .orange,
                instructions: """
                    Clean up dictated speech. Remove filler words and false starts. Fix obvious \
                    mis-transcriptions. Keep the speaker's wording, tone and language — do not \
                    translate, summarise, answer, or add anything. Return only the cleaned text.
                    """,
                isBuiltIn: true
            ),
            Mode(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!,
                name: "Email",
                symbol: "envelope",
                tint: .blue,
                instructions: """
                    Clean up dictated speech into a written message. Full sentences, correct \
                    punctuation, paragraph breaks where the speaker paused on a new thought. Keep \
                    the speaker's tone and language. Do not add a greeting or sign-off that was \
                    not spoken. Return only the message text.
                    """,
                appBundleIDs: ["com.apple.mail", "com.readdle.smartemail-Mac", "com.superhuman.electron"],
                isBuiltIn: true
            ),
            Mode(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!,
                name: "Code",
                symbol: "chevron.left.forwardslash.chevron.right",
                tint: .graphite,
                instructions: """
                    Clean up dictated speech from a programmer. Keep identifiers, symbols and \
                    casing exactly as spoken. Do not rewrite it into prose and do not add \
                    punctuation that was not spoken. Return only the cleaned text.
                    """,
                cleanup: CleanupOptions(
                    removeFillers: true,
                    resolveSelfCorrections: true,
                    spokenPunctuation: false,
                    sentenceCase: false,
                    applyVocabulary: true,
                    tidyWhitespace: true
                ),
                appBundleIDs: [
                    "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
                    "com.jetbrains.intellij", "dev.warp.Warp-Stable", "com.googlecode.iterm2",
                    "com.apple.Terminal",
                ],
                isBuiltIn: true
            ),
            Mode(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!,
                name: "Chat",
                symbol: "bubble.left.and.bubble.right",
                tint: .green,
                instructions: """
                    Clean up dictated speech for an instant message. Keep it short and casual, the \
                    way the speaker said it. Light punctuation only. Do not formalise it. Return \
                    only the cleaned text.
                    """,
                cleanup: CleanupOptions(
                    removeFillers: true,
                    resolveSelfCorrections: true,
                    spokenPunctuation: true,
                    sentenceCase: false,
                    applyVocabulary: true,
                    tidyWhitespace: true
                ),
                appBundleIDs: ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp"],
                isBuiltIn: true
            ),
            Mode(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000A005")!,
                name: "Raw",
                symbol: "waveform",
                tint: .purple,
                instructions: "",
                cleanup: .none,
                isBuiltIn: true
            ),
        ]
    }
}

// MARK: - Lenient decoding

/// See `LenientDecoding.swift`. A mode file that cannot be decoded is quarantined by
/// `JSONFileStore`, which would present as "the app forgot all my modes" after an upgrade.
extension Mode {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Mode(name: "Mode", symbol: "sparkles", instructions: "")
        id = container.value(.id, or: UUID())
        name = container.value(.name, or: defaults.name)
        symbol = container.value(.symbol, or: defaults.symbol)
        tint = container.value(.tint, or: defaults.tint)
        instructions = container.value(.instructions, or: defaults.instructions)
        cleanup = container.value(.cleanup, or: defaults.cleanup)
        usesClipboardContext = container.value(.usesClipboardContext, or: defaults.usesClipboardContext)
        pastesClipboard = container.value(.pastesClipboard, or: defaults.pastesClipboard)
        appBundleIDs = container.value(.appBundleIDs, or: defaults.appBundleIDs)
        isBuiltIn = container.value(.isBuiltIn, or: defaults.isBuiltIn)
    }
}

extension CleanupOptions {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CleanupOptions()
        removeFillers = container.value(.removeFillers, or: defaults.removeFillers)
        resolveSelfCorrections = container.value(.resolveSelfCorrections, or: defaults.resolveSelfCorrections)
        spokenPunctuation = container.value(.spokenPunctuation, or: defaults.spokenPunctuation)
        sentenceCase = container.value(.sentenceCase, or: defaults.sentenceCase)
        applyVocabulary = container.value(.applyVocabulary, or: defaults.applyVocabulary)
        tidyWhitespace = container.value(.tidyWhitespace, or: defaults.tidyWhitespace)
    }
}
