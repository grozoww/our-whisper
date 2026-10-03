import Foundation
import OSLog

/// Optional cloud transcription through Soniox.
///
/// This exists for one reason: Parakeet covers 25 European languages, and Chinese and Japanese are
/// not among them. Rather than shipping a second local model on a hunch, the languages the offline
/// engine cannot do are routed here — with the user's own key, only when they ask.
///
/// The flow is upload → start job → poll → fetch, which is Soniox's asynchronous API. The
/// streaming WebSocket API would give partial results sooner, but the app records a complete
/// utterance before transcribing anything, so there is nothing to stream.
actor SonioxProvider: TranscriptionProvider {
    nonisolated let id: TranscriptionProviderID = .soniox
    nonisolated var displayName: String { "Soniox" }

    /// Soniox charges by audio second, so a job that never finishes costs nothing but time. This
    /// bounds the wait so a stuck job surfaces as an error rather than a spinner forever.
    private static let pollTimeout: Duration = .seconds(120)
    private static let pollInterval: Duration = .milliseconds(700)

    private static let baseURL = URL(string: "https://api.soniox.com")!

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "soniox")
    private let http: any HTTPClient
    private let model: String
    /// Read at call time rather than cached, so pasting a new key takes effect immediately and a
    /// deleted key stops working immediately. Also means the key is never held in memory between
    /// dictations.
    private let keyProvider: @Sendable () -> String?

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        model: String = "stt-async-preview",
        keyProvider: @escaping @Sendable () -> String? = { KeychainStore.read(.soniox) }
    ) {
        self.http = http
        self.model = model
        self.keyProvider = keyProvider
    }

    /// A cloud engine has nothing to load. It is ready exactly when there is a key to use.
    var isReady: Bool { keyProvider() != nil }

    func prepare(progress: (@Sendable (SpeechModelProgress) -> Void)? = nil) async throws {
        guard keyProvider() != nil else {
            throw TranscriptionError.engine("Add a Soniox API key in Configuration to use the cloud model.")
        }
    }

    func unload() async {}

    func transcribe(samples: [Float], language: SpeechLanguage) async throws -> Transcription {
        guard let key = keyProvider() else {
            throw TranscriptionError.engine("Add a Soniox API key in Configuration to use the cloud model.")
        }
        guard samples.count >= Int(AudioCapture.targetSampleRate * 0.3) else {
            throw TranscriptionError.tooShort
        }

        let started = ContinuousClock.now
        let audio = WAVEncoder.encode(samples: samples)
        log.info("Uploading \(audio.count) bytes to Soniox")

        let fileID = try await uploadFile(audio, key: key)
        let jobID = try await startTranscription(fileID: fileID, language: language, key: key)
        try await waitForCompletion(jobID: jobID, key: key)
        let text = try await fetchTranscript(jobID: jobID, key: key)

        // Best effort. A leftover file costs the user storage on Soniox's side, and there is
        // nothing useful to tell them if cleanup fails, so a failure here must not fail the
        // dictation that already succeeded.
        await deleteFile(fileID, key: key)

        return Transcription(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            // Soniox reports per-token confidence; a single number for the utterance would be
            // invented, so this reports the one honest thing: the transcript arrived.
            confidence: 1,
            audioDuration: Double(samples.count) / AudioCapture.targetSampleRate,
            processingTime: Double(started.duration(to: .now).components.seconds)
                + Double(started.duration(to: .now).components.attoseconds) / 1e18
        )
    }

    // MARK: - API steps

    private func uploadFile(_ audio: Data, key: String) async throws -> String {
        let boundary = "ourwhisper.\(UUID().uuidString)"
        var request = authorized(URL(string: "/v1/files", relativeTo: Self.baseURL)!, key: key)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(contentsOf: Array("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Array("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n".utf8))
        body.append(contentsOf: Array("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(contentsOf: Array("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let json = try await sendExpectingJSON(request)
        guard let id = json["id"] as? String else {
            throw HTTPError.malformedResponse("upload response had no file id")
        }
        return id
    }

    private func startTranscription(fileID: String, language: SpeechLanguage, key: String) async throws -> String {
        var request = authorized(URL(string: "/v1/transcriptions", relativeTo: Self.baseURL)!, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = ["file_id": fileID, "model": model]
        // Hints bias the model without forcing it, which is what `auto` wants: send nothing and
        // let Soniox detect.
        if !language.hints.isEmpty {
            payload["language_hints"] = language.hints
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let json = try await sendExpectingJSON(request)
        guard let id = json["id"] as? String else {
            throw HTTPError.malformedResponse("transcription response had no job id")
        }
        return id
    }

    private func waitForCompletion(jobID: String, key: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.pollTimeout)

        while ContinuousClock.now < deadline {
            let request = authorized(URL(string: "/v1/transcriptions/\(jobID)", relativeTo: Self.baseURL)!, key: key)
            let json = try await sendExpectingJSON(request)
            let status = json["status"] as? String

            switch status {
            case "completed":
                return
            case "error", "failed":
                let detail = json["error_message"] as? String ?? "the provider did not say why"
                throw TranscriptionError.engine("Soniox could not transcribe this: \(detail)")
            default:
                try await Task.sleep(for: Self.pollInterval)
            }
        }

        throw TranscriptionError.engine("Soniox did not finish within \(Self.pollTimeout.components.seconds) seconds.")
    }

    private func fetchTranscript(jobID: String, key: String) async throws -> String {
        let request = authorized(
            URL(string: "/v1/transcriptions/\(jobID)/transcript", relativeTo: Self.baseURL)!,
            key: key
        )
        let json = try await sendExpectingJSON(request)

        if let text = json["text"] as? String {
            return text
        }
        // Older responses carry tokens instead of an assembled string. Soniox's tokens already
        // include their own leading spaces, so they concatenate rather than join.
        if let tokens = json["tokens"] as? [[String: Any]] {
            return tokens.compactMap { $0["text"] as? String }.joined()
        }
        throw HTTPError.malformedResponse("transcript response had neither text nor tokens")
    }

    private func deleteFile(_ fileID: String, key: String) async {
        var request = authorized(URL(string: "/v1/files/\(fileID)", relativeTo: Self.baseURL)!, key: key)
        request.httpMethod = "DELETE"
        _ = try? await http.send(request)
    }

    // MARK: - Plumbing

    private func authorized(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // Long enough for a slow upload on hotel wifi, short enough that a dead network gives up
        // while the user is still looking at the pill.
        request.timeoutInterval = 60
        return request
    }

    private func sendExpectingJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.from(status: response.statusCode, body: data)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.malformedResponse("expected a JSON object")
        }
        return json
    }
}
