import Foundation
import OSLog

/// What the speech model is doing right now, in the words a person waiting on it would use.
///
/// The Home screen, the Models library and the hotkey all need to answer "can I dictate yet?", and
/// before this existed each of them answered from something different. Home read the controller's
/// phase and called everything "downloading"; the library read the disk and called the same files
/// "installed" the moment they existed; the hotkey read the phase too, and the phase went back to
/// idle 2.5 seconds after the first refused press while the model was still being prepared. All
/// three were describing one thing, and a user who sat at "50%" for minutes — the progress bar
/// FluidAudio drives is the first half of each model's download and the second half of its CoreML
/// compile, and the compile does not move it — restarted the app, was told the files were
/// installed, and still could not dictate. This is the one answer they all read now.
@MainActor
@Observable
final class SpeechModelStatus {
    enum State: Equatable, Sendable {
        /// Nothing is happening and the model is not in memory. The files may or may not be on disk.
        case notLoaded
        /// Preparing has begun and nothing has been reported yet: the repository is being listed or
        /// the files are being opened.
        case starting
        case downloading(Double)
        /// CoreML is compiling the model for this Mac's Neural Engine. Nothing reports how far
        /// along that is, which is why there is no fraction here: a bar frozen at 50% for minutes
        /// reads as a hang, where a spinner and a clock read as work.
        case optimizing
        case ready
        case failed(String)

        /// Preparation is under way, so a dictation cannot start and a second preparation would
        /// only wait on the first.
        var isBusy: Bool {
            switch self {
            case .starting, .downloading, .optimizing: true
            case .notLoaded, .ready, .failed: false
            }
        }
    }

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "speech-model")

    private(set) var state: State

    /// When the current preparation began, so the screen can say how long it has been going.
    private(set) var startedAt: Date?

    /// Called when a preparation ends, either way. The Models library keeps what is on disk as
    /// stored state — a directory walk is not something a view body may do — and this is how it
    /// learns the files have just arrived.
    var onFinish: (() -> Void)?

    private var preparation: Task<Void, Error>?

    /// - Parameter state: Only for tests, which cannot wait out a real download to see a screen in
    ///   the middle of one.
    init(state: State = .notLoaded) {
        self.state = state
    }

    /// Downloads and loads the model, reporting as it goes. Every caller awaits the same work.
    ///
    /// The launch path, the Models library's button and the hotkey can all ask at once. The
    /// provider joins them too, but a caller that joins there gets no progress and nothing here
    /// would be told it had started — which is how the library came to say "installed" while the
    /// controller's preparation was still compiling.
    func prepare(using provider: ParakeetProvider) async throws {
        try await prepare { report in try await provider.prepare(progress: report) }
    }

    /// The same, for any work that reports progress. Separate so the state machine can be tested
    /// with work that finishes when the test says so.
    func prepare(
        _ work: @escaping @Sendable (@escaping @Sendable (SpeechModelProgress) -> Void) async throws -> Void
    ) async throws {
        if case .ready = state { return }
        if let preparation { return try await preparation.value }

        state = .starting
        startedAt = .now
        log.info("Preparing the speech model")
        let task = Task { [weak self] in
            try await work { update in
                Task { @MainActor in self?.apply(update) }
            }
        }
        preparation = task
        defer { preparation = nil }

        do {
            try await task.value
            state = .ready
            log.info("Speech model ready after \(Int(Date.now.timeIntervalSince(self.startedAt ?? .now))) s")
            onFinish?()
        } catch {
            state = .failed(error.localizedDescription)
            log.error("Speech model failed: \(error.localizedDescription, privacy: .public)")
            onFinish?()
            throw error
        }
    }

    /// For after the provider has been unloaded and its files deleted.
    func reset() {
        guard preparation == nil else { return }
        state = .notLoaded
        startedAt = nil
    }

    /// Updates arrive on a queue of FluidAudio's choosing and are hopped here one at a time, so a
    /// late one can land after the preparation has finished. It is dropped rather than allowed to
    /// turn "ready" back into "optimizing".
    func apply(_ update: SpeechModelProgress) {
        guard preparation != nil else { return }
        let before = state
        switch update {
        case .downloading(let fraction): state = .downloading(fraction)
        case .optimizing: state = .optimizing
        }
        // Each change of stage, never each percent: this is what answers "what was it doing when it
        // looked stuck", and a line per megabyte would bury that.
        switch (before, state) {
        case (.downloading, .downloading), (.optimizing, .optimizing): break
        case (_, .downloading): log.info("Speech model: downloading")
        case (_, .optimizing): log.info("Speech model: optimizing for the Neural Engine")
        default: break
        }
    }

    /// What a press of the hotkey should do, given what the speech model is doing.
    ///
    /// Pure, because "the hotkey said nothing and the second press recorded a sentence and failed"
    /// was a bug about this decision, and a decision is what a test can hold still.
    enum Gate: Equatable {
        /// Nothing in the way: record.
        case proceed
        /// The model is on its way. Say how, and do not record — the pill has room for one line,
        /// so this is the short version of what Home says at length.
        case wait(String)
        /// The model is not loaded and nothing is loading it, so waiting would not help. Start it
        /// and say so: a failed attempt, a model that was removed, or one nobody asked for until
        /// the engine or the language was switched.
        case loadFirst(String)
    }

    /// `usesSpeechModel` is whether this dictation goes to Parakeet at all. A dictation routed to
    /// the cloud engine has no use for a model that is not there, and must not be held up by it.
    static func gate(for state: State, usesSpeechModel: Bool) -> Gate {
        guard usesSpeechModel else { return .proceed }
        switch state {
        case .ready: return .proceed
        case .starting: return .wait("Speech model is still loading")
        case .downloading(let fraction): return .wait("Speech model is downloading — \(Int(fraction * 100))%")
        case .optimizing: return .wait("Speech model is optimizing for this Mac")
        case .notLoaded, .failed: return .loadFirst("Speech model is not loaded — loading it")
        }
    }
}
