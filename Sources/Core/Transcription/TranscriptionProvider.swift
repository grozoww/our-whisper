import Foundation

/// One transcription engine. Local and cloud engines both conform, so choosing between them is a
/// dropdown rather than a branch through the rest of the app.
protocol TranscriptionProvider: Actor {
    nonisolated var id: TranscriptionProviderID { get }
    nonisolated var displayName: String { get }

    /// True once the engine can accept audio. Downloading counts as not ready.
    /// Actor-isolated, so callers await it; conformers cache it rather than probing the model.
    var isReady: Bool { get }


    /// Downloads and loads whatever the engine needs. Safe to call repeatedly; later calls with
    /// models already loaded return immediately.
    func prepare(progress: (@Sendable (SpeechModelProgress) -> Void)?) async throws

    /// Transcribes one complete utterance of 16 kHz mono float samples.
    func transcribe(samples: [Float], language: SpeechLanguage) async throws -> Transcription

    /// Frees model memory. Called when the user switches engines.
    func unload() async
}

/// What an engine reports while it gets ready: which of two very different waits this is.
///
/// A single fraction used to carry both, and the two do not behave alike. Bytes arrive at a
/// steady rate and a bar means something; a CoreML compile reports nothing until it is done and
/// can take minutes, so a bar for it just sits still and looks like a hang.
enum SpeechModelProgress: Sendable, Equatable {
    /// Bytes are arriving. `fraction` is how much of the model in flight has come.
    case downloading(fraction: Double)
    /// Compiling for this Mac's Neural Engine. No fraction: nothing says how far along it is.
    case optimizing
}

enum TranscriptionProviderID: String, Codable, Sendable {
    case parakeet
    case soniox
}

struct Transcription: Sendable, Equatable {
    var text: String
    var confidence: Float
    /// Length of the audio, not of the work.
    var audioDuration: TimeInterval
    /// How long the engine took. The ratio of the two is what makes a model feel fast or slow.
    var processingTime: TimeInterval

    var realtimeFactor: Double {
        processingTime > 0 ? audioDuration / processingTime : 0
    }

    static let empty = Transcription(text: "", confidence: 0, audioDuration: 0, processingTime: 0)
}

enum TranscriptionError: LocalizedError {
    case notReady
    case languageNotSupported(SpeechLanguage, by: String)
    case tooShort
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            "The speech model is still loading."
        case .languageNotSupported(let language, let engine):
            "\(engine) does not support \(language.displayName). Switch to a cloud model for this language."
        case .tooShort:
            "That recording was too short to transcribe."
        case .engine(let detail):
            detail
        }
    }
}
