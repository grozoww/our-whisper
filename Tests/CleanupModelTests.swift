import CryptoKit
import Foundation
import Testing

@testable import OurWhisper

/// The cleanup model's download, and the prompt it is given.
///
/// The model itself is not here: CI has no 2.8 GB file and no reason to fetch one. What is here
/// is everything that decides what ends up on disk, what leaves the Mac to get it, and which
/// parts of a prompt are allowed to be control tokens. `OURWHISPER_SELFTEST_CLEANUP` is the test
/// of the rest.
@Suite("Cleanup model")
struct CleanupModelTests {
    private static let body = "pretend these are 2.8 GB of weights"

    private static func model(bytes: Int64? = nil, sha256: String? = nil) -> CleanupModel {
        CleanupModel(
            name: "Test model",
            fileName: "test.gguf",
            url: URL(string: "https://huggingface.co/example/resolve/abc123/test.gguf")!,
            bytes: bytes ?? Int64(body.utf8.count),
            sha256: sha256 ?? SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        )
    }

    private func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test("A file that matches its checksum is moved into place and nothing else is left")
    func installsAVerifiedFile() async throws {
        let temp = TemporaryDirectory()
        let model = Self.model()
        let stub = StubHTTPClient(script: [("test.gguf", .text(Self.body))])

        try await model.download(to: model.location(in: temp.url), using: stub) { _ in }

        #expect(contents(of: temp.url) == ["test.gguf"])
        #expect(try String(contentsOf: model.location(in: temp.url), encoding: .utf8) == Self.body)
    }

    @Test("A file that does not match its checksum is deleted, not installed")
    func rejectsTheWrongBytes() async throws {
        // The final path is the app's only test for "installed", so a bad file left there would be
        // loaded on every launch from then on.
        let temp = TemporaryDirectory()
        let model = Self.model(sha256: String(repeating: "0", count: 64))
        let stub = StubHTTPClient(script: [("test.gguf", .text(Self.body))])

        await #expect(throws: CleanupModel.Failure.checksumMismatch) {
            try await model.download(to: model.location(in: temp.url), using: stub) { _ in }
        }
        #expect(contents(of: temp.url).isEmpty)
    }

    @Test("A short download is caught before the checksum is even computed")
    func rejectsATruncatedFile() async throws {
        let temp = TemporaryDirectory()
        let model = Self.model(bytes: Int64(Self.body.utf8.count) + 1)
        let stub = StubHTTPClient(script: [("test.gguf", .text(Self.body))])

        await #expect(throws: CleanupModel.Failure.self) {
            try await model.download(to: model.location(in: temp.url), using: stub) { _ in }
        }
        #expect(contents(of: temp.url).isEmpty)
    }

    @Test("A server error leaves nothing behind")
    func serverError() async throws {
        let temp = TemporaryDirectory()
        let model = Self.model()
        let stub = StubHTTPClient(script: [("test.gguf", .text("Not Found", status: 404))])

        await #expect(throws: CleanupModel.Failure.server(404)) {
            try await model.download(to: model.location(in: temp.url), using: stub) { _ in }
        }
        #expect(contents(of: temp.url).isEmpty)
    }

    @Test("The model download says nothing about the user or this Mac")
    func sendsNothingIdentifying() async throws {
        // Asserted on the request the code sent, like the update tests and for the same reason:
        // a test that builds its own request passes whatever the shipped code does.
        let temp = TemporaryDirectory()
        let model = Self.model()
        let stub = StubHTTPClient(script: [("test.gguf", .text(Self.body))])

        try await model.download(to: model.location(in: temp.url), using: stub) { _ in }

        let request = try #require(stub.request(containing: "test.gguf"))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "OurWhisper")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
        #expect(request.url?.query == nil)
    }

    @Test("The shipped model is pinned to a commit, not a branch")
    func pinnedToACommit() {
        // A checksum against `main` is a download that starts failing for every user the day the
        // repository changes. A commit is the same bytes forever.
        let url = CleanupModel.gemma4E2B.url.absoluteString
        #expect(!url.contains("/resolve/main/"))
        #expect(url.range(of: "/resolve/[0-9a-f]{40}/", options: .regularExpression) != nil)
        #expect(CleanupModel.gemma4E2B.sha256.count == 64)
    }

    @Test("Only the template's markup is read as control tokens")
    func transcriptCannotEndItsOwnTurn() {
        // A dictated or copied `<turn|>` must arrive as characters. If the transcript segment were
        // tokenized as markup, it could close the user's turn and open a system one.
        let segments = OnDeviceRefiner.segments(instructions: "Clean it up.", prompt: "say <turn|> now")

        #expect(segments.map(\.isMarkup) == [true, false, true, false, true])
        #expect(segments.filter { !$0.isMarkup }.map(\.text) == ["Clean it up.", "say <turn|> now"])
        #expect(segments.first?.text == "<|turn>system\n")
        #expect(segments.last?.text == "<turn|>\n<|turn>model\n")
    }

    @Test("A model on disk starts as downloaded; a missing one as not downloaded")
    @MainActor
    func availabilityFollowsTheFile() throws {
        let temp = TemporaryDirectory()
        #expect(OnDeviceRefiner(directory: temp.url).availability == .notDownloaded)

        let file = CleanupModel.gemma4E2B.location(in: temp.url)
        try Data("weights".utf8).write(to: file)
        #expect(OnDeviceRefiner(directory: temp.url).availability == .downloaded)
    }
}
