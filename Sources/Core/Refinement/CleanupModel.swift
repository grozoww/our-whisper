import Foundation

/// A language model file the app downloads: where it comes from, how big it is, and the checksum it
/// has to match. Named for the first one it carried — cleanup — and now also the assistant's.
///
/// The URL names a commit, not `main`. A checksum against a moving branch is a download that
/// starts failing for every user the day the repository is updated, with nothing wrong on either
/// end; a commit is the same bytes forever, which is what the checksum is asserting.
struct CleanupModel: Sendable, Equatable {
    let name: String
    let fileName: String
    let url: URL
    let bytes: Int64
    let sha256: String

    /// Gemma 4 E2B, instruction-tuned, quantised to 4 bits by the llama.cpp project itself.
    ///
    /// E2B because it is the smallest Gemma 4 and the cleanup prompt does not need more: measured
    /// on an M1 Max, it answers in 0.5–1.5 s and keeps Russian and Ukrainian as Russian and
    /// Ukrainian. Q4_0 because it is the fastest quantisation on Metal and ggml-org publishes it.
    static let gemma4E2B = CleanupModel(
        name: "Gemma 4 E2B",
        fileName: "gemma-4-E2B-it-Q4_0.gguf",
        url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/b4243c156154b6dca9324415f8c7ccc098b4aed1/gemma-4-E2B-it-Q4_0.gguf")!,
        bytes: 2_841_481_184,
        sha256: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
    )

    /// Gemma 4 E4B, the larger sibling, for the assistant mode only.
    ///
    /// From Google's model card, E2B to E4B: MMLU Pro 60.0 to 69.4, multilingual MMMLU 67.4 to 76.6,
    /// instruction following over turns (Tau2) 24.5 to 42.2 — the things a summarise-and-reply mode
    /// lives on, and the multilingual one matters because Russian and Ukrainian are first-class
    /// here. It costs 1.75 GB more disk and, measured on an M1 Max, writes about 35 tokens a second
    /// against E2B's 55 — and, the reason it is here at all, it ignored an instruction planted in
    /// the clipboard in all 18 Russian runs and 18 English ones, where E2B typed what a Russian one
    /// told it to type in all 5. Dictation
    /// cleanup stays on E2B: 0.35 s there is not worth the slower model. Same commit-pinning
    /// rule as above; the bytes and checksum are the ones Hugging Face publishes for that commit.
    static let gemma4E4B = CleanupModel(
        name: "Gemma 4 E4B",
        fileName: "gemma-4-E4B-it-Q4_0.gguf",
        url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/b8093469224f83f5c38f691eb906c380e9e63114/gemma-4-E4B-it-Q4_0.gguf")!,
        bytes: 4_590_807_392,
        sha256: "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2"
    )

    func location(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    enum Failure: LocalizedError, Equatable {
        case server(Int)
        case truncated(expected: Int64, got: Int64)
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .server(let status):
                "The model download failed (HTTP \(status))."
            case .truncated:
                "The model download was cut short."
            case .checksumMismatch:
                "The downloaded model did not match its checksum, so it was deleted."
            }
        }
    }

    /// Downloads the file beside its final location, checks it, and only then moves it into place.
    ///
    /// The final path is the app's only test for "installed", so nothing may ever sit there that
    /// was not verified: a half-written file there would be loaded on the next launch. The
    /// partial file is deleted on every failure, including a checksum that does not match.
    ///
    /// The request goes through `UpdateChecker.anonymousRequest` for the same reason the update
    /// check does — URLSession's own `User-Agent` and `Accept-Language` would tell Hugging Face
    /// the app version, the exact macOS build and the user's region.
    func download(
        to destination: URL,
        using http: any HTTPClient,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            let total = bytes
            // The update check's request gives up after 15 seconds of silence, which suits a JSON
            // answer and not a 2.8 GB file: one CDN stall would throw away the whole download.
            var request = UpdateChecker.anonymousRequest(url)
            request.timeoutInterval = 120
            let response = try await http.download(request, to: partial) { written in
                progress(min(1, Double(written) / Double(total)))
            }
            guard (200..<300).contains(response.statusCode) else { throw Failure.server(response.statusCode) }

            let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path(percentEncoded: false))
            let onDisk = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard onDisk == bytes else { throw Failure.truncated(expected: bytes, got: onDisk) }

            let actual = try await Task.detached { try UpdateInstaller.sha256(of: partial) }.value
            guard actual == sha256 else { throw Failure.checksumMismatch }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}
