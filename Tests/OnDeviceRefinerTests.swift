import Foundation
import Testing

@testable import OurWhisper

/// The cleanup model's lifecycle, as far as it can be driven without 2.8 GB of weights: what a
/// failed download leaves behind, what asking twice does, and what the wording promises.
@Suite("Cleanup model lifecycle")
@MainActor
struct OnDeviceRefinerTests {
    private func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private static let shortBody = "nowhere near 2.8 GB"
    private static var fileName: String { OnDeviceRefiner.cleanupModel.fileName }

    @Test("A download that comes up short is a failure that says what to expect, and leaves nothing behind")
    func failureIsExplainedAndClean() async throws {
        let temp = TemporaryDirectory()
        let stub = StubHTTPClient(script: [(Self.fileName, .text(Self.shortBody))])
        let refiner = OnDeviceRefiner(directory: temp.url, http: stub)

        await refiner.prepare()

        guard case .failed(let message) = refiner.availability else {
            Issue.record("expected a failure, got \(refiner.availability)")
            return
        }
        // What went wrong, and when it will be tried again — a failure with no next step reads as
        // a dead end.
        #expect(message.contains("cut short"))
        #expect(message.contains("next launch"))
        #expect(contents(of: temp.url).isEmpty)
        #expect(!refiner.availability.isAvailable)
    }

    @Test("Asking again after a failure tries again")
    func retries() async throws {
        let temp = TemporaryDirectory()
        let stub = StubHTTPClient(script: [
            (Self.fileName, .text(Self.shortBody)),
            (Self.fileName, .text(Self.shortBody)),
        ])
        let refiner = OnDeviceRefiner(directory: temp.url, http: stub)

        await refiner.prepare()
        await refiner.prepare()

        #expect(stub.requests.count == 2)
    }

    @Test("Callers who arrive while it is downloading share the one download")
    func sharesTheDownload() async {
        // Launch, the Configuration switch and the Models button can all ask at once. A second
        // 2.8 GB download of the same file helps nobody.
        let temp = TemporaryDirectory()
        let stub = StubHTTPClient(script: [
            (Self.fileName, .text(Self.shortBody)),
            (Self.fileName, .text(Self.shortBody)),
        ])
        let refiner = OnDeviceRefiner(directory: temp.url, http: stub)

        async let first: Void = refiner.prepare()
        async let second: Void = refiner.prepare()
        _ = await (first, second)

        #expect(stub.requests.count == 1)
    }

    @Test("Removing deletes the file and goes back to not downloaded")
    func removes() async throws {
        let temp = TemporaryDirectory()
        let file = OnDeviceRefiner.cleanupModel.location(in: temp.url)
        try Data("weights".utf8).write(to: file)
        let refiner = OnDeviceRefiner(directory: temp.url)
        #expect(refiner.availability == .downloaded)

        await refiner.remove()

        #expect(refiner.availability == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Switching it off keeps the file, so switching it back on is a load and not a download")
    func unloadKeepsTheFile() async throws {
        let temp = TemporaryDirectory()
        let file = OnDeviceRefiner.cleanupModel.location(in: temp.url)
        try Data("weights".utf8).write(to: file)
        let refiner = OnDeviceRefiner(directory: temp.url)

        await refiner.unload()

        #expect(refiner.availability == .downloaded)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Every state says something, and none of them is a bare error code")
    func everyStateHasWords() {
        for availability in [
            OnDeviceRefiner.Availability.notDownloaded, .downloading(0.4), .downloaded, .loading, .available,
        ] {
            #expect(availability.explanation.count > 20, "\(availability)")
        }
        #expect(OnDeviceRefiner.Availability.downloading(0.38).explanation.contains("38%"))
        // The download is automatic, so the one place it can be stopped has to be named.
        #expect(OnDeviceRefiner.Availability.downloading(0.38).explanation.contains("Switch this off"))
    }
}
