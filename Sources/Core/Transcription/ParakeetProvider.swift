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

    /// Where the files are. `nil` is FluidAudio's own folder, which is the one the Models library
    /// shows and removes; only a test passes another, so a test never loads — or deletes — the
    /// user's real 600 MB.
    private let directory: URL?

    /// The load in flight, which every caller that arrives while it runs joins.
    private var preparation: Task<Void, Error>?

    init(directory: URL? = nil) {
        self.directory = directory
    }

    /// Whether the model's files are already on this Mac. What tells a failed *load* — worth
    /// trying again, nothing needs the network — from a failed download, which is not retried on a
    /// timer.
    nonisolated var isOnDisk: Bool {
        AsrModels.modelsExist(at: directory ?? AsrModels.defaultCacheDirectory(for: .v3))
    }

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
            let models = try await downloadAndLoad(progress: progress)
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
            // The whole error and not its one-line description: CoreML says "Unable to load model"
            // for a truncated file and for a Mac that was too busy to compile one, and the domain
            // and code are what tell them apart afterwards.
            log.error("Parakeet failed to load: \(String(describing: error), privacy: .public)")
            throw TranscriptionError.engine(error.localizedDescription)
        }
    }

    /// Fetches what is missing and loads it — without ever letting FluidAudio delete files that are
    /// already here.
    ///
    /// FluidAudio takes any failed load that is not a cancellation or a network error for a corrupt
    /// file: it deletes the whole model folder, all four models, and downloads them again. A load
    /// can fail for other reasons — CoreML throws the same "Unable to load model" for a truncated
    /// file and for a Mac too busy to compile one — and then the folder is gone while, right after
    /// login, the network may not be up either. The re-download fails, nothing is left, and the next
    /// launch downloads 600 MB from nothing. That is the path behind "my models disappear after the
    /// Mac restarts and download again, and opening the app a second time is fine". What the load
    /// actually failed with was never captured, which is why `load` now logs the whole error.
    ///
    /// `ModelHub.offlineMode` is FluidAudio's own switch for exactly this: with it on, a failed load
    /// is reported and nothing is deleted. It is a process-wide flag, so it is set only for the
    /// length of this call, which `preparation` already keeps to one at a time, and cleared on every
    /// way out — a flag left on would make every later download fail.
    private func downloadAndLoad(progress: (@Sendable (SpeechModelProgress) -> Void)?) async throws -> AsrModels {
        let report: ProgressHandler = { update in
            if let reported = Self.progress(from: update) { progress?(reported) }
        }
        guard isOnDisk else {
            // Nothing here to lose, and a download is what is wanted.
            return try await AsrModels.downloadAndLoad(to: directory, version: .v3, progressHandler: report)
        }

        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        do {
            return try await AsrModels.downloadAndLoad(to: directory, version: .v3, progressHandler: report)
        } catch DownloadError.modelMissing {
            // FluidAudio counts a file as missing — or a cache as left by an older release of its
            // own — that `isOnDisk` did not. That is not a load that failed, it is files FluidAudio
            // itself says are not the ones it needs, and fetching them is the right answer.
            ModelHub.offlineMode = false
            log.info("FluidAudio found its cache incomplete; fetching what is missing")
            return try await AsrModels.downloadAndLoad(to: directory, version: .v3, progressHandler: report)
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
