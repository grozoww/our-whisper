import Foundation
import LlamaSwift
import OSLog

/// One GGUF model loaded through llama.cpp, and the context it generates in.
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

    private let queue = DispatchSerialQueue(label: "com.grozoww.ourwhisper.llama", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    var isLoaded: Bool { context != nil }

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

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = Self.contextLength
        contextParameters.n_batch = Self.contextLength
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw Failure(message: "The cleanup model loaded but could not start. Restart OurWhisper and try again.")
        }

        // Greedy: the same sentence must clean up the same way twice. A model that paraphrases
        // differently on each press is unusable for dictation.
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        self.model = model
        self.context = context
        self.sampler = sampler

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
    func generate(_ segments: [PromptSegment], maxTokens: Int) throws -> String {
        guard let model, let context, let sampler else {
            throw Failure(message: "The cleanup model is not loaded.")
        }
        let vocab = llama_model_get_vocab(model)

        var prompt: [llama_token] = []
        for (index, segment) in segments.enumerated() {
            prompt += Self.tokenize(segment.text, vocab: vocab, addBOS: index == 0, parseMarkup: segment.isMarkup)
        }

        let room = Int(Self.contextLength) - prompt.count
        guard room > 16 else {
            throw Failure(message: "The transcript is too long for the cleanup model.")
        }

        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)

        let status = prompt.withUnsafeMutableBufferPointer {
            llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
        }
        guard status == 0 else { throw Failure(message: "The cleanup model failed to read the prompt (\(status)).") }

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

    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        context = nil
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
