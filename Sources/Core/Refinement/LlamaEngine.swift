import Foundation
import LlamaSwift
import OSLog

/// One GGUF model loaded through llama.cpp, and the contexts it generates in.
///
/// An actor on its own serial queue rather than on the shared pool, because every llama.cpp call
/// blocks: a load maps 2.8 GB, a generation runs for about a second, and holding a cooperative
/// thread that long starves everything else waiting for one. The queue is also what lets
/// `shutdown` run synchronously on the way out — see there for why it has to.
actor LlamaEngine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Room for the instructions, a 2,000-character clipboard reference, several minutes of
    /// dictation and an answer as long again. A prompt that does not fit is skipped rather than
    /// cut, because the model cleaning half a transcript would paste half a transcript.
    static let contextLength: UInt32 = 8192

    /// What the lookup needs is its examples, about 2,500 tokens, and the sentence, with no answer
    /// to speak of. Half the room, and the memory that goes with it: a context costs about 200 MB
    /// at the full size.
    static let lookupContextLength: UInt32 = 4096

    private let queue = DispatchSerialQueue(label: "com.grozoww.ourwhisper.llama", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Independent contexts on the one loaded model. A context is where the keys and values of the
    /// prompt live, so one that alternates between two different prompts re-reads the long shared
    /// start of each every time. The clipboard lookup's start is a page of examples and is the same
    /// on every call; given its own context it is read once and every later call pays only for the
    /// sentence on the end.
    ///
    /// The lookup's context is made the first time it is asked for, not at load: most people never
    /// switch the clipboard on, and a context is memory they would be holding for nothing.
    enum Slot: Hashable {
        case cleanup
        case lookup

        var contextLength: UInt32 {
            switch self {
            case .cleanup: LlamaEngine.contextLength
            case .lookup: LlamaEngine.lookupContextLength
            }
        }
    }

    private struct Session {
        let context: OpaquePointer
        let sampler: UnsafeMutablePointer<llama_sampler>
        /// What the context holds from the last prompt. Empty whenever it cannot be trusted — at
        /// the start of a call, and after any failure — so a half-finished call can only cost a
        /// full re-read, never a wrong answer.
        var cached: [llama_token] = []
    }

    private var model: OpaquePointer?
    private var sessions: [Slot: Session] = [:]

    var isLoaded: Bool { model != nil }

    func load(from url: URL) throws {
        guard model == nil else { return }

        _ = Self.initialiseBackend
        var modelParameters = llama_model_default_params()
        // Every layer on the GPU. llama.cpp maps the file and hands Metal the mapping, so this
        // costs no copy of the weights.
        modelParameters.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(url.path(percentEncoded: false), modelParameters) else {
            throw Failure(message: "The cleanup model could not be loaded. Remove it in Models and download it again.")
        }

        let cleanup: Session
        do {
            cleanup = try Self.makeSession(on: model, slot: .cleanup)
        } catch {
            llama_model_free(model)
            throw error
        }

        self.model = model
        self.sessions = [.cleanup: cleanup]

        // The first decode compiles the Metal kernels, about half a second on an M1 Max. Paid
        // here, at launch, rather than by the first dictation.
        _ = try? generate([PromptSegment(text: "Hi", isMarkup: false)], maxTokens: 1)
    }

    /// Runs the prompt and returns what the model wrote, stopping at its end-of-turn token or at
    /// `maxTokens`, whichever is first.
    ///
    /// Checks for cancellation between tokens. That is what makes the caller's timeout real: the
    /// C call cannot be interrupted, but a generation is hundreds of short calls, and stopping
    /// between two of them frees the engine for the next dictation instead of finishing an answer
    /// nobody is waiting for.
    ///
    /// With `reusingStart`, whatever the context already holds of this prompt's beginning is kept
    /// and only the rest is read. Off for cleanup, whose start is the mode's instructions and a
    /// hundred tokens; on for the lookup, whose start is the examples and a thousand.
    func generate(
        _ segments: [PromptSegment],
        maxTokens: Int,
        in slot: Slot = .cleanup,
        reusingStart: Bool = false
    ) throws -> String {
        guard let model else {
            throw Failure(message: "The cleanup model is not loaded.")
        }
        var session = try sessions[slot] ?? Self.makeSession(on: model, slot: slot)
        let vocab = llama_model_get_vocab(model)
        let context = session.context
        let sampler = session.sampler

        var prompt: [llama_token] = []
        for (index, segment) in segments.enumerated() {
            prompt += Self.tokenize(segment.text, vocab: vocab, addBOS: index == 0, parseMarkup: segment.isMarkup)
        }

        let room = Int(slot.contextLength) - prompt.count
        guard room > 16 else {
            throw Failure(message: "The transcript is too long for the cleanup model.")
        }

        // Distrusted until the prompt has been read in full.
        let held = session.cached
        session.cached = []
        sessions[slot] = session

        // Always leaves the last token to be read: decoding needs something to produce a next token
        // from, and an identical prompt twice would otherwise have nothing left to decode.
        var reused = 0
        let memory = llama_get_memory(context)
        if reusingStart {
            let limit = min(held.count, prompt.count - 1)
            while reused < limit, held[reused] == prompt[reused] { reused += 1 }
        }
        // A partial removal can be refused, and then the whole context goes — slower, never wrong.
        if reused == 0 || !llama_memory_seq_rm(memory, 0, Int32(reused), -1) {
            llama_memory_clear(memory, true)
            reused = 0
        }
        llama_sampler_reset(sampler)

        let unread = Array(prompt[reused...])
        let status = unread.withUnsafeBufferPointer {
            llama_decode(context, llama_batch_get_one(UnsafeMutablePointer(mutating: $0.baseAddress), Int32($0.count)))
        }
        guard status == 0 else { throw Failure(message: "The cleanup model failed to read the prompt (\(status)).") }
        session.cached = prompt
        sessions[slot] = session

        var output: [UInt8] = []
        for _ in 0..<min(maxTokens, room) {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += Self.piece(token, vocab: vocab)
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else {
                throw Failure(message: "The cleanup model failed while writing.")
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func makeSession(on model: OpaquePointer, slot: Slot) throws -> Session {
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = slot.contextLength
        contextParameters.n_batch = slot.contextLength
        guard let context = llama_init_from_model(model, contextParameters) else {
            throw Failure(message: "The cleanup model loaded but could not start. Restart OurWhisper and try again.")
        }

        // Greedy: the same sentence must clean up the same way twice. A model that paraphrases
        // differently on each press is unusable for dictation.
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            llama_free(context)
            throw Failure(message: "The cleanup model loaded but could not start. Restart OurWhisper and try again.")
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        return Session(context: context, sampler: sampler)
    }

    private static func free(_ sessions: Dictionary<Slot, Session>.Values) {
        for session in sessions {
            llama_sampler_free(session.sampler)
            llama_free(session.context)
        }
    }

    func unload() {
        Self.free(sessions.values)
        if let model { llama_model_free(model) }
        sessions = [:]
        model = nil
    }

    /// Frees the model before the process exits, from outside the actor and without awaiting.
    ///
    /// Not tidiness: llama.cpp's Metal backend asserts in a static destructor when a context is
    /// still alive at `exit`, so quitting with the model loaded is a crash report on every quit.
    /// `applicationWillTerminate` cannot await, hence the queue. Waits for a generation in flight,
    /// which is bounded by its token limit.
    nonisolated func shutdown() {
        queue.sync { self.assumeIsolated { $0.unload() } }
    }

    // MARK: - Tokens

    /// Markup is the template's own turn tokens. Everything else — the instructions, the
    /// transcript, the clipboard — is tokenized with control tokens read as plain text, so a
    /// dictated or copied `<turn|>` is characters rather than the end of the user's turn.
    private static func tokenize(
        _ text: String,
        vocab: OpaquePointer?,
        addBOS: Bool,
        parseMarkup: Bool
    ) -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        let count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addBOS, parseMarkup)
        return Array(tokens.prefix(Int(max(count, 0))))
    }

    /// Bytes rather than a string, because a multi-byte character — every Cyrillic letter — can
    /// be split across two tokens, and decoding each half on its own would leave two replacement
    /// characters where one letter should be.
    private static func piece(_ token: llama_token, vocab: OpaquePointer?) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        let count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        return buffer.prefix(Int(max(count, 0))).map { UInt8(bitPattern: $0) }
    }

    /// Once per process. llama.cpp logs every tensor it loads to stderr; only its errors are
    /// worth keeping, and they go where the rest of the app's logs go.
    private static let initialiseBackend: Void = {
        llama_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            Logger(subsystem: "com.grozoww.ourwhisper", category: "refine")
                .error("llama.cpp: \(String(cString: text), privacy: .public)")
        }, nil)
        llama_backend_init()
    }()
}

/// A piece of a prompt, and whether control tokens in it are read as control tokens.
struct PromptSegment: Equatable, Sendable {
    let text: String
    let isMarkup: Bool
}
