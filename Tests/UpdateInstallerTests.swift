import CryptoKit
import Foundation
import Testing

@testable import OurWhisper

@Suite("Installing an update")
struct UpdateInstallerTests {
    // MARK: - SHA256SUMS

    /// The file `package.sh` writes with `shasum -a 256`, verbatim: two spaces between the digest
    /// and the name.
    private let sums = """
    73b4ad1b1a1c1e04ef0c7ecb3c6e2b3b0f0a3f5f2a2c9d8e7f6a5b4c3d2e1f00  OurWhisper-1.0.15-unnotarized.dmg
    2f5a9c8e7d6b5a4938271605f4e3d2c1b0a9988776655443322110ffeeddccbb  OurWhisper-1.0.15.dmg
    """

    @Test("The checksum is taken from the line naming that exact file")
    func findsChecksum() {
        #expect(
            UpdateInstaller.checksum(for: "OurWhisper-1.0.15-unnotarized.dmg", in: sums)
                == "73b4ad1b1a1c1e04ef0c7ecb3c6e2b3b0f0a3f5f2a2c9d8e7f6a5b4c3d2e1f00"
        )
    }

    @Test("A filename that is a substring of another is not confused with it")
    func doesNotMatchOnSubstring() {
        // `scripts/install.sh` matches with `grep -F`, so "OurWhisper-1.0.15.dmg" also matches the
        // "-unnotarized" line above it. Reading the wrong digest fails the comparison and refuses
        // an update that was perfectly fine, which reads as "the updater is broken".
        #expect(
            UpdateInstaller.checksum(for: "OurWhisper-1.0.15.dmg", in: sums)
                == "2f5a9c8e7d6b5a4938271605f4e3d2c1b0a9988776655443322110ffeeddccbb"
        )
    }

    @Test("Binary mode's asterisk before the name is not part of the name")
    func stripsBinaryMarker() {
        let sums = "73b4ad1b1a1c1e04ef0c7ecb3c6e2b3b0f0a3f5f2a2c9d8e7f6a5b4c3d2e1f00 *OurWhisper.dmg"
        #expect(UpdateInstaller.checksum(for: "OurWhisper.dmg", in: sums) != nil)
    }

    @Test("A file with no entry for the download answers nothing, rather than the first digest")
    func missingEntry() {
        #expect(UpdateInstaller.checksum(for: "OurWhisper-2.0.0.dmg", in: sums) == nil)
    }

    @Test("Lines that are not a digest and a name are skipped", arguments: [
        "",
        "not a checksum at all",
        "abc  OurWhisper.dmg",                                              // too short to be SHA-256
        "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz  OurWhisper.dmg",  // not hex
        "73b4ad1b1a1c1e04ef0c7ecb3c6e2b3b0f0a3f5f2a2c9d8e7f6a5b4c3d2e1f00",  // no filename
    ])
    func ignoresJunk(line: String) {
        #expect(UpdateInstaller.checksum(for: "OurWhisper.dmg", in: line) == nil)
    }

    @Test("A name containing a space is read whole")
    func nameWithSpace() {
        let sums = "73b4ad1b1a1c1e04ef0c7ecb3c6e2b3b0f0a3f5f2a2c9d8e7f6a5b4c3d2e1f00  Our Whisper.dmg"
        #expect(UpdateInstaller.checksum(for: "Our Whisper.dmg", in: sums) != nil)
    }

    // MARK: - Hashing

    @Test("The file hash matches the published vector")
    func hashesAFile() throws {
        // "abc" is the canonical SHA-256 test vector, so this fails if the chunking is wrong
        // rather than if some other implementation disagrees.
        let temp = TemporaryDirectory()
        let file = temp.url.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        #expect(
            try UpdateInstaller.sha256(of: file)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("A file larger than one chunk hashes the same as one read whole")
    func hashesAcrossChunks() throws {
        // The read loop is 1 MB at a time, so anything smaller never exercises the second pass.
        let temp = TemporaryDirectory()
        let file = temp.url.appendingPathComponent("big.bin")
        let bytes = Data((0..<(3 * (1 << 20) + 17)).map { UInt8($0 % 251) })
        try bytes.write(to: file)

        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try UpdateInstaller.sha256(of: file) == expected)
    }

    // MARK: - Whether this build may replace itself

    // MARK: - Whether this build may replace itself

    @Test("A bundle in a writable directory can be replaced")
    func installableWhereWritable() {
        let temp = TemporaryDirectory()
        let app = temp.url.appendingPathComponent("OurWhisper.app", isDirectory: true)
        // Both ways of asking: the cheap one the button uses, and the write probe `perform` does.
        #expect(UpdateInstaller.installability(of: app) == .ok)
        #expect(UpdateInstaller.installability(of: app, probingWrite: false) == .ok)
        #expect(UpdateInstaller.installability(of: app).refusal == nil)
    }

    @Test("A bundle whose folder cannot be written to is refused, and says where")
    func refusesUnwritableParent() throws {
        let temp = TemporaryDirectory()
        let parent = temp.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Readable and searchable, not writable — a standard user's view of a root-owned folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }

        let app = parent.appendingPathComponent("OurWhisper.app")
        #expect(UpdateInstaller.installability(of: app) == .notWritable(parent))
        #expect(UpdateInstaller.installability(of: app, probingWrite: false) == .notWritable(parent))
        #expect(UpdateInstaller.installability(of: app).refusal?.contains(parent.path) == true)
    }

    @Test("A translocated copy is refused before anything is downloaded")
    func refusesTranslocation() {
        // macOS runs a quarantined app from a read-only shadow copy, so the path the app sees is
        // not where anyone installed it and replacing it would achieve nothing.
        let app = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC-123/d/OurWhisper.app")
        #expect(UpdateInstaller.installability(of: app) == .translocated)
    }

    // MARK: - Handing the new copy the old one's pid

    @Test("The pid to wait for is read off the command line")
    func readsPredecessorPID() {
        #expect(UpdateInstaller.predecessorPID(in: ["/Applications/OurWhisper.app", "--awaiting-pid", "4213"]) == 4213)
    }

    @Test("An ordinary launch waits for nobody", arguments: [
        [String](),
        ["/Applications/OurWhisper.app"],
        ["--awaiting-pid"],
        ["--awaiting-pid", "not-a-number"],
        ["--awaiting-pid", "0"],
        ["--awaiting-pid", "-1"],
    ])
    func noPredecessor(arguments: [String]) {
        // A launch with nothing to wait for must start immediately. Blocking on a pid that was
        // never passed would hang the app for ten seconds on every ordinary open.
        #expect(UpdateInstaller.predecessorPID(in: arguments) == nil)
    }

    @Test("Waiting does not return until the copy being replaced has gone")
    @MainActor
    func waitsForThePredecessorToExit() async throws {
        // The claim is that the successor holds off, so the test has to be able to catch it
        // returning early: a `waitForPredecessor` that ignored the pid would come back while the
        // child was still alive.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.5"]
        try process.run()

        await UpdateInstaller.waitForPredecessor(arguments: ["--awaiting-pid", String(process.processIdentifier)])
        #expect(!process.isRunning)
    }

    // MARK: - Fetching, and what it sends

    private static let body = "a disk image, near enough"

    private func release(dmgSize: Int64? = nil, dmgName: String = "OurWhisper-9.9.9-unnotarized.dmg") -> UpdateChecker.Release {
        UpdateChecker.Release(
            version: "9.9.9",
            title: "Nine",
            notes: "",
            url: URL(string: "https://github.com/grozoww/our-whisper/releases/tag/v9.9.9")!,
            publishedAt: nil,
            dmg: UpdateChecker.Asset(
                name: dmgName,
                url: URL(string: "https://github.com/grozoww/our-whisper/releases/download/v9.9.9/\(dmgName)")!,
                size: dmgSize ?? Int64(Self.body.utf8.count)
            ),
            checksums: URL(string: "https://github.com/grozoww/our-whisper/releases/download/v9.9.9/SHA256SUMS")!
        )
    }

    private func stub(digest: String, name: String = "OurWhisper-9.9.9-unnotarized.dmg") -> StubHTTPClient {
        StubHTTPClient(script: [
            (".dmg", .text(Self.body)),
            ("SHA256SUMS", .text("\(digest)  \(name)")),
        ])
    }

    private var digestOfBody: String {
        SHA256.hash(data: Data(Self.body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Neither request the download makes says anything about the user or this Mac")
    @MainActor
    func sendsNothingIdentifyingWhenDownloading() async throws {
        // CLAUDE.md's rule 3 names this test, so it has to be able to fail. Asserting on a request
        // the test built itself passes whatever the shipped code sends — replacing both call sites
        // with a bare `URLRequest(url:)` left a suite of 187 green. This drives the real code and
        // reads back what it actually sent.
        let temp = TemporaryDirectory()
        let stub = stub(digest: digestOfBody)
        let installer = UpdateInstaller(http: stub)

        _ = try await installer.fetch(release(), into: temp.url)

        for path in [".dmg", "SHA256SUMS"] {
            let request = try #require(stub.request(containing: path))
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "OurWhisper")
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.httpBody == nil)
            #expect(request.url?.query == nil)
        }
    }

    @Test("The download is written under a name of the app's choosing, never GitHub's")
    @MainActor
    func writesUnderAFixedName() async throws {
        // `appendingPathComponent` splices a string into a path and leaves `../` for the kernel, so
        // an asset name is a way to put the response body — bytes wholly of the sender's choosing —
        // outside the staging directory, before the size, the checksum and the signature have had
        // a chance to reject any of it, and outside what the cleanup removes.
        let temp = TemporaryDirectory()
        let staging = temp.url.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let hostile = "../escaped.dmg"
        let installer = UpdateInstaller(http: stub(digest: digestOfBody, name: hostile))
        let image = try await installer.fetch(release(dmgName: hostile), into: staging)

        #expect(image.lastPathComponent == "update.dmg")
        #expect(image.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("escaped.dmg").path))
    }

    @Test("A download that does not match its published checksum is refused")
    @MainActor
    func refusesAChecksumMismatch() async throws {
        let temp = TemporaryDirectory()
        let wrong = String(repeating: "0", count: 64)
        let installer = UpdateInstaller(http: stub(digest: wrong))

        await #expect(throws: UpdateInstaller.Failure.self) {
            _ = try await installer.fetch(self.release(), into: temp.url)
        }
    }

    @Test("A download that stopped early is refused before it is hashed")
    @MainActor
    func refusesATruncatedDownload() async throws {
        // The release says how many bytes there should be, and comparing two numbers is free.
        let temp = TemporaryDirectory()
        let installer = UpdateInstaller(http: stub(digest: digestOfBody))

        await #expect(throws: UpdateInstaller.Failure.self) {
            _ = try await installer.fetch(self.release(dmgSize: 999_999), into: temp.url)
        }
    }

    @Test("A release with no disk image, or no checksums, is refused rather than guessed at")
    @MainActor
    func refusesAnIncompleteRelease() async throws {
        let temp = TemporaryDirectory()
        let full = release()
        let noImage = UpdateChecker.Release(
            version: full.version, title: full.title, notes: full.notes, url: full.url,
            publishedAt: nil, dmg: nil, checksums: full.checksums
        )
        let noSums = UpdateChecker.Release(
            version: full.version, title: full.title, notes: full.notes, url: full.url,
            publishedAt: nil, dmg: full.dmg, checksums: nil
        )
        let installer = UpdateInstaller(http: stub(digest: digestOfBody))

        await #expect(throws: UpdateInstaller.Failure.self) { _ = try await installer.fetch(noImage, into: temp.url) }
        await #expect(throws: UpdateInstaller.Failure.self) { _ = try await installer.fetch(noSums, into: temp.url) }
    }

    // MARK: - The signature check

    /// A real, ad-hoc-signed bundle, so the check runs against a signature rather than a hope.
    ///
    /// Not the test host: CI builds it with `CODE_SIGNING_ALLOWED=NO`, so its resources are never
    /// sealed and verifying it fails with `errSecCSResourcesNotSealed` on every runner while
    /// passing on every developer's Mac. A bundle the test signs itself behaves the same
    /// everywhere, and can be tampered with on purpose.
    private func signedProbe(in temp: TemporaryDirectory, identifier: String = "com.grozoww.probe") throws -> URL {
        let app = temp.url.appendingPathComponent("Probe.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        // Any Mach-O will do as the executable; codesign needs one to sign a bundle at all.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Probe"))
        try Data("sealed".utf8).write(to: contents.appendingPathComponent("Resources/sealed.txt"))
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Probe",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "Probe",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        return app
    }

    @Test("This app's own requirement can be read")
    func readsTheRunningRequirement() throws {
        // The first thing `perform` does. An unsigned test host still has a linker signature, so
        // this works on CI as well as on a signed build; what it says differs, what matters is
        // that it answers.
        #expect(try !BundleSignature.runningRequirement().isEmpty)
    }

    @Test("A signed bundle satisfies a requirement it meets")
    func verifiesASignedBundle() throws {
        let temp = TemporaryDirectory()
        let probe = try signedProbe(in: temp)
        try BundleSignature.verify(probe, satisfies: #"identifier "com.grozoww.probe""#)
    }

    @Test("A bundle that does not meet the requirement is the wrong signer, not damaged")
    func rejectsAnotherSigner() throws {
        // The two have to be distinguishable, because the sentence the user is shown differs: one
        // means someone else built it, the other means the bytes are broken.
        let temp = TemporaryDirectory()
        let probe = try signedProbe(in: temp)
        #expect(throws: BundleSignature.Failure.wrongSigner) {
            try BundleSignature.verify(probe, satisfies: #"identifier "com.example.someone-else""#)
        }
    }

    @Test("A sealed resource changed after signing makes the bundle damaged")
    func rejectsATamperedBundle() throws {
        // This is the case a string comparison of designated requirements cannot catch: the
        // tampered bundle still reports the same requirement as the genuine one.
        let temp = TemporaryDirectory()
        let probe = try signedProbe(in: temp)
        try Data("sealed?".utf8).write(to: probe.appendingPathComponent("Contents/Resources/sealed.txt"))

        do {
            try BundleSignature.verify(probe, satisfies: #"identifier "com.grozoww.probe""#)
            Issue.record("a bundle with a modified sealed resource verified")
        } catch BundleSignature.Failure.damaged {
            // The right refusal.
        }
    }

    @Test("A path with no bundle at it is a failure, not a pass")
    func rejectsAMissingBundle() {
        #expect(throws: BundleSignature.Failure.self) {
            try BundleSignature.verify(
                URL(fileURLWithPath: "/nonexistent/OurWhisper.app"),
                satisfies: #"identifier "com.grozoww.ourwhisper""#
            )
        }
    }

    @Test("Whether an update can satisfy a requirement is judged on its shape, not on a word", arguments: [
        // A cdhash pin names one exact binary, whatever else is in the string.
        (#"cdhash H"a1b2c3d4e5f60718293a4b5c6d7e8f9012345678""#, false),
        (#"identifier "com.example.certificate-pinning" and cdhash H"a1b2c3d4e5f6""#, false),
        // Certificate and anchor clauses are both satisfiable by a later build.
        (#"identifier "com.grozoww.ourwhisper" and certificate leaf = H"5b6de378c4c3aed97f3908f35096b845621014b7""#, true),
        (#"identifier "com.grozoww.ourwhisper" and anchor apple generic"#, true),
        // The word inside an identifier literal must not vote.
        (#"identifier "com.example.certificate""#, false),
        // What a build signed with a Developer ID really reports, copied from `codesign -d -r-` on
        // this app signed with the project's own. It names the team and no leaf, so every later
        // build from the same account satisfies it — and if this ever answered "no", the first
        // Developer ID build would refuse to update itself as though it were ad-hoc.
        (#"identifier "com.grozoww.ourwhisper" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = D6U6DW65Y7"#, true),
    ])
    func judgesRequirementShape(requirement: String, satisfiable: Bool) {
        #expect(BundleSignature.namesACertificate(requirement) == satisfiable)
    }

    // MARK: - What the row says

    @Test("Every installer phase has a sentence, and none of them is empty")
    func everyPhaseSaysSomething() {
        // The row's detail line is the only place a failure is reported, so a phase that fell
        // through to an empty string would be a silent failure on screen.
        let release = release()
        let phases: [UpdateInstaller.Phase] = [
            .idle, .downloading(0.1), .downloading(nil), .verifying, .installing,
            .restarting, .installedNeedsRestart, .failed("no"),
        ]
        for phase in phases {
            #expect(!UpdateActions.detail(phase: phase, refusal: nil, release: release).isEmpty)
        }

        // A build that cannot update itself says why in place of the release title.
        #expect(UpdateActions.detail(phase: .idle, refusal: "Ad-hoc signed.", release: release) == "Ad-hoc signed.")
        // A failure outranks a refusal: it is the thing that just happened.
        #expect(UpdateActions.detail(phase: .failed("boom"), refusal: "ad-hoc", release: release) == "boom")

        #expect(UpdateActions.isWarning(phase: .idle, refusal: nil) == false)
        #expect(UpdateActions.isWarning(phase: .idle, refusal: "ad-hoc") == true)
        #expect(UpdateActions.isWarning(phase: .failed("boom"), refusal: nil) == true)
        // An installed update waiting on a restart is finished work, not a problem.
        #expect(UpdateActions.isWarning(phase: .installedNeedsRestart, refusal: nil) == false)
    }

    @Test("A downloaded body lands on disk unchanged")
    func writesTheBodyToDisk() async throws {
        let temp = TemporaryDirectory()
        let file = temp.url.appendingPathComponent("OurWhisper.dmg")
        let stub = StubHTTPClient(script: [(".dmg", .text("disk image"))])

        _ = try await stub.download(URLRequest(url: URL(string: "https://example.invalid/a.dmg")!), to: file) { _ in }

        #expect(try Data(contentsOf: file) == Data("disk image".utf8))
    }
}
