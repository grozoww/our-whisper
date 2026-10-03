import FluidAudio
import Foundation
import OSLog

/// Offline transcription with NVIDIA Parakeet TDT v3, running on the Neural Engine through
/// FluidAudio's CoreML runtime.
///
/// Chosen over Whisper on evidence rather than reputation: on FLEURS it scores 3.00% WER on
/// Russian against Whisper large-v3's 4.04%, and 5.10% against 12.52% on Ukrainian, while being
/// roughly 11x faster and a third of the size.
actor ParakeetProvider: TranscriptionProvider {
    nonisolated let id: TranscriptionProviderID = .parakeet
    nonisolated var displayName: String { "Parakeet TDT v3" }

    /// Below this the model has nothing to work with. Roughly a third of a second — shorter than
    /// any real word plus the delay between speaking and releasing the key.
    private static let minimumSamples = Int(AudioCapture.targetSampleRate * 0.3)

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "parakeet")

    private var manager: AsrManager?

    /// The load in flight, which every caller that arrives while it runs joins.
    private var preparation: Task<Void, Error>?

    /// Cached rather than asking the manager each time: `AsrManager.isAvailable` is
    /// actor-isolated, and an async getter cannot satisfy the protocol's requirement.
    private(set) var isReady = false

    func prepare(progress: (@Sendable (SpeechModelProgress) -> Void)? = nil) async throws {
        if isReady { return }

        // Two hotkey presses in quick succession must not start two downloads. Whoever arrives
        // first owns the load; everyone else awaits the same task. The task is also what records
        // the result, so a caller that only waited cannot return before `isReady` is true — it
        // could, because the owner set it after resuming and a joiner might resume first.
        if let preparation { return try await preparation.value }

        let task = Task { try await self.load(progress: progress) }
        preparation = task
        // Cleared on failure too, so the next attempt retries instead of awaiting a failure for ever.
        defer { if preparation == task { preparation = nil } }
        try await task.value
    }

    private func load(progress: (@Sendable (SpeechModelProgress) -> Void)?) async throws {
        log.info("Loading Parakeet TDT v3…")
        do {
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { update in
                    if let reported = Self.progress(from: update) { progress?(reported) }
                }
            )
            let loaded = AsrManager(config: .default)
            try await loaded.loadModels(models)

            guard await loaded.isAvailable else {
                throw TranscriptionError.engine("The speech model loaded but cannot run on this Mac.")
            }
            manager = loaded
            isReady = true
            log.info("Parakeet ready")
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.engine(error.localizedDescription)
        }
    }

    /// Turns FluidAudio's one number into which of the two waits this is.
    ///
    /// FluidAudio loads the four models one after another, and for each of them reports the
    /// download as the first half of 0...1 and the CoreML compile as the second half. So the bar it
    /// drives fills, jumps to 50% when the compile starts, sits there for as long as the compile
    /// takes — 30 seconds from a cold cache on an M1 Max, longer on a slower Mac — and then goes
    /// back to the start for the next model. Read as one progress bar that is a download which hangs
    /// at half and begins again; read as two different waits it is exactly what is happening.
    ///
    /// Pure and `nonisolated` so the mapping can be tested with FluidAudio's own types.
    nonisolated static func progress(from update: DownloadProgress) -> SpeechModelProgress? {
        switch update.phase {
        case .listing:
            // Asking Hugging Face what there is. Nothing to show yet.
            return nil
        case .downloading(_, let totalFiles):
            // No files means the cache was complete: FluidAudio announces "download finished" for
            // files it did not download, on its way to the compile.
            guard totalFiles > 0 else { return nil }
            return .downloading(fraction: min(1, max(0, update.fractionCompleted * 2)))
        case .compiling:
            return .optimizing
        }
    }

    func transcribe(samples: [Float], language: SpeechLanguage) async throws -> Transcription {
        guard language.isLocal else {
            throw TranscriptionError.languageNotSupported(language, by: displayName)
        }
        guard samples.count >= Self.minimumSamples else {
            throw TranscriptionError.tooShort
        }
        guard let manager, isReady else {
            throw TranscriptionError.notReady
        }

        do {
            // Fresh decoder state per utterance. The state carries linguistic context across
            // chunks of one recording, which is what we want inside a sentence — and emphatically
            // not what we want between two unrelated dictations minutes apart.
            var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)

            let result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: Self.fluidLanguage(for: language)
            )
            return Transcription(
                text: result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                confidence: result.confidence,
                audioDuration: result.duration,
                processingTime: result.processingTime
            )
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.engine(error.localizedDescription)
        }
    }

    func unload() async {
        preparation?.cancel()
        preparation = nil
        await manager?.cleanup()
        manager = nil
        isReady = false
    }

    /// Maps our UI language to FluidAudio's. Passing one biases token selection toward that
    /// script, which is what stops a Ukrainian sentence coming back half-transliterated.
    /// `nil` lets the model decide.
    private static func fluidLanguage(for language: SpeechLanguage) -> Language? {
        switch language {
        case .auto: nil
        case .english: .english
        case .russian: .russian
        case .ukrainian: .ukrainian
        case .spanish: .spanish
        case .german: .german
        case .french: .french
        case .polish: .polish
        // Handled by dedicated models, not this one — `isLocal` rejects them above.
        case .chinese, .japanese: nil
        }
    }
}
