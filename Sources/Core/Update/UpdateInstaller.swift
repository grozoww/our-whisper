import AppKit
import CryptoKit
import Foundation
import Observation
import OSLog

/// Downloads the release `UpdateChecker` found, installs it over this app, and restarts into it.
///
/// Only ever on a button press. `UpdateChecker` is allowed to run on its own because it sends
/// nothing and downloads nothing; a 12 MB transfer is a different promise, so nothing here is
/// wired to `checkAutomatically`, there is no pre-fetch and there is no retry timer.
///
/// The order of the steps is the design, and it is chosen so that "the user is left with no
/// working app" is unreachable rather than unlikely. Everything is downloaded, checked, expanded
/// and verified *beside* the installed app; the app itself is touched exactly once, by a single
/// filesystem operation that either happens or does not. `scripts/install.sh` deletes the old
/// bundle and copies the new one in its place, which is right when a human is watching a terminal
/// and wrong here.
///
/// There are no fallbacks. Every failure before the swap is a refusal that leaves the user exactly
/// where they were, with one sentence saying what to do — installing anyway on a failed signature,
/// skipping the checksum, or copying over the bundle when the swap will not go are each a way of
/// turning a refusal into a broken Mac. After the swap there is nothing left to refuse, so the one
/// thing that can still fail — the relaunch — ends in `installedNeedsRestart`, which is true and
/// says what to do rather than reporting a failure that did not happen.
@MainActor
@Observable
final class UpdateInstaller {
    enum Phase: Equatable, Sendable {
        case idle
        /// `nil` when the release did not say how big the image is, which is the difference
        /// between a bar and a spinner rather than a bar stuck at nothing.
        case downloading(Double?)
        case verifying
        case installing
        /// The swap is done and the app is on its way out. The next thing that happens is the
        /// process ending.
        case restarting
        /// The swap is done and the app could not restart itself. Not a failure — the update is
        /// installed and complete; it takes effect the next time OurWhisper is opened.
        case installedNeedsRestart
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .installing, .restarting: true
            case .idle, .installedNeedsRestart, .failed: false
            }
        }
    }

    private(set) var phase: Phase = .idle

    /// Set once by `AppState`. The installer does not know what a dictation is, and these are the
    /// two things it has to ask the app before it takes the app away: whether now is a moment when
    /// quitting costs the user something, and a chance to get its stores onto disk first.
    var isSafeToRestart: (@MainActor () -> Bool)?
    var flushBeforeRestart: (@MainActor () -> Void)?

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "update")
    private let http: any HTTPClient

    /// Worked out once per launch. It cannot change while the process runs — the code signature
    /// and the bundle's location are both fixed by then — and reading it means a round trip to the
    /// security daemon, which two screens would otherwise pay for on every appearance.
    private var refusalIsKnown = false
    private var knownRefusal: String?

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    // MARK: - The one public thing

    func install(_ release: UpdateChecker.Release) async {
        guard !phase.isBusy else { return }
        do {
            try await perform(release)
        } catch {
            log.error("Update install failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// Why this build cannot install an update, or `nil` when it can.
    ///
    /// Asked before the button is drawn as well as before the work starts, so a build that can
    /// never self-update says why instead of offering a button that always fails. The display-time
    /// answer deliberately does not write a probe file into `/Applications`; `perform` does that
    /// once, when there is actually something to install.
    var refusal: String? {
        if refusalIsKnown { return knownRefusal }
        refusalIsKnown = true

        guard let requirement = try? BundleSignature.runningRequirement() else {
            knownRefusal = "This copy of OurWhisper has no readable code signature, so an update cannot be checked against it."
            return knownRefusal
        }
        guard BundleSignature.namesACertificate(requirement) else {
            knownRefusal = Failure.adHoc.errorDescription
            return knownRefusal
        }
        knownRefusal = Self.installability(of: Bundle.main.bundleURL, probingWrite: false).refusal
        return knownRefusal
    }

    // MARK: - The steps

    private func perform(_ release: UpdateChecker.Release) async throws {
        let destination = Bundle.main.bundleURL

        // Read before anything is written. `SecCodeCopySelf` resolves through the bundle's path,
        // so once the swap has happened this answers with the *new* app's requirement — a check
        // written after the copy compares the incoming build against itself and cannot fail.
        let requirement = try BundleSignature.runningRequirement()
        guard BundleSignature.namesACertificate(requirement) else { throw Failure.adHoc }
        if let refusal = Self.installability(of: destination).refusal { throw Failure.refused(refusal) }

        // On the same volume as the app, which is what lets the swap be a rename rather than a
        // copy. Application Support would be the wrong side of that line on a Mac with more than
        // one disk, and the swap would fail after the download had already been spent.
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        // Only covers the paths that throw. The success path removes it explicitly, because
        // `NSApplication.terminate` does not return and a `defer` after it never runs — which
        // would leave the disk image behind on every successful update.
        do {
            let image = try await fetch(release, into: staging)

            phase = .installing
            let staged = try await Self.expand(image, as: destination.lastPathComponent, into: staging)

            // The staged copy, not the one inside the disk image: these are the exact bytes about
            // to become the app, and `ditto` is one more thing that can go wrong between the two.
            phase = .verifying
            try await Self.verify(staged, satisfies: requirement)
            log.info("Signature satisfies this app's requirement: \(requirement, privacy: .public)")

            // Asked here, while refusing still costs nothing but the download. The button is
            // disabled during a dictation, but the download takes seconds and one can begin under
            // it — and the swap is the last moment at which "not now" is still free.
            guard isSafeToRestart?() ?? true else { throw Failure.busy }

            phase = .installing
            // One operation, and the app is either the old one or the new one. The running process
            // is unharmed: its pages are mapped from the old inode, which stays alive, unlinked,
            // until it exits. Copying over the bundle in place instead reuses the inode and macOS
            // kills the process on the next page-in.
            let installed = try FileManager.default.replaceItemAt(destination, withItemAt: staged) ?? destination
            log.info("Installed \(release.version, privacy: .public) over \(UpdateChecker.currentVersion, privacy: .public)")

            try? FileManager.default.removeItem(at: staging)

            phase = .restarting
            // Before the successor launches, not after: it loads settings, modes, vocabulary and
            // history in its own `init`, so anything still sitting in the coalescing window would
            // be read stale and then written back over the flush this process is about to make.
            flushBeforeRestart?()

            do {
                log.info("Relaunching \(installed.path(percentEncoded: false), privacy: .public)")
                try await Self.relaunch(installed)
                log.info("Successor is running; exiting")
            } catch {
                // The update is installed and correct. Only the restart failed, and saying
                // "failed" here would be a lie that sends the user looking for a broken download.
                log.error("Update installed but the relaunch failed: \(error.localizedDescription, privacy: .public)")
                phase = .installedNeedsRestart
                return
            }
            NSApplication.shared.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Downloads the disk image and checks that it is the one the release published.
    ///
    /// Separate from `perform`, and reachable from a test, because this is where the app's second
    /// network request is made. A privacy test that builds its own `URLRequest` and asserts on it
    /// passes whatever the shipped code sends; only a test that drives this and reads the requests
    /// back off a stub can fail when someone drops the `anonymousRequest` wrapper.
    func fetch(_ release: UpdateChecker.Release, into staging: URL) async throws -> URL {
        guard let asset = release.dmg else { throw Failure.noDiskImage }
        guard let checksums = release.checksums else { throw Failure.noChecksums }

        // A fixed local name, never the one GitHub supplied. `appendingPathComponent` splices a
        // string into a path and leaves `../` for the kernel to resolve, so an asset named
        // `../../evil` would put the response body — bytes entirely of the sender's choosing —
        // outside the staging directory, before the size, the checksum and the signature have had
        // a chance to reject any of it, and outside what the cleanup removes. The name is still
        // needed to find the right line of `SHA256SUMS`, which is a string comparison and cannot
        // escape anything.
        let image = staging.appendingPathComponent("update.dmg", isDirectory: false)

        phase = .downloading(asset.size > 0 ? 0 : nil)
        log.info("Downloading \(asset.name, privacy: .public) (\(asset.size) bytes)")
        let total = asset.size
        // Weak here as well as on the hop: an outer closure that names no capture list holds
        // `self` strongly for the inner one, and the hop's `weak` would then be weak in name only.
        let response = try await http.download(UpdateChecker.anonymousRequest(asset.url), to: image) { [weak self] written in
            guard total > 0 else { return }
            Task { @MainActor [weak self] in
                // Clamped so it only ever goes forwards: each step hops to the main actor to be
                // observed, and those hops arrive in whatever order they like.
                guard let self, case .downloading(let shown) = self.phase else { return }
                self.phase = .downloading(max(shown ?? 0, min(1, Double(written) / Double(total))))
            }
        }
        guard (200..<300).contains(response.statusCode) else { throw Failure.github(response.statusCode) }

        phase = .verifying
        let attributes = try? FileManager.default.attributesOfItem(atPath: image.path(percentEncoded: false))
        let onDisk = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if asset.size > 0, onDisk != asset.size { throw Failure.truncated(expected: asset.size, got: onDisk) }

        let (data, sumsResponse) = try await http.send(UpdateChecker.anonymousRequest(checksums))
        guard (200..<300).contains(sumsResponse.statusCode) else { throw Failure.github(sumsResponse.statusCode) }
        guard let expected = Self.checksum(for: asset.name, in: String(decoding: data, as: UTF8.self)) else {
            throw Failure.noChecksumForImage(asset.name)
        }
        let actual = try await Task.detached { try Self.sha256(of: image) }.value
        guard actual == expected else { throw Failure.checksumMismatch }
        log.info("Checksum matches SHA256SUMS")

        return image
    }

    /// The checksum `SHA256SUMS` records for one filename.
    ///
    /// `shasum -a 256` writes `<64 hex><two spaces><name>`, with a `*` before the name for a file
    /// read in binary mode. Matched on the whole filename, not `scripts/install.sh`'s `grep -F`
    /// substring — a substring also matches a longer name that happens to contain this one.
    ///
    /// Pure, so the format is tested rather than assumed.
    nonisolated static func checksum(for filename: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let digest = String(fields[0])
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            let name = fields.dropFirst().joined(separator: " ")
            if name.drop(while: { $0 == "*" }) == filename { return digest.lowercased() }
        }
        return nil
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verify(_ bundle: URL, satisfies requirement: String) async throws {
        try await Task.detached { try BundleSignature.verify(bundle, satisfies: requirement) }.value
    }

    // MARK: - Getting the app out of the disk image

    private static func expand(_ image: URL, as name: String, into staging: URL) async throws -> URL {
        // Mounted *outside* the staging directory, and that is not a tidiness choice. A volume
        // mounted anywhere under `TemporaryItems` — inside the `NSIRD_` directory or beside it —
        // is off limits to an app without Full Disk Access, which never prompts and simply
        // refuses, so the first read of the mounted app failed with "you don't have permission"
        // and the install stopped there. Measured from a LaunchServices-launched app on macOS 26:
        // the same image reads fine at `/Volumes`, `/tmp`, `$TMPDIR` or `~/Library/Caches`. A test
        // from a shell passes in every location, because Terminal carries permissions the app
        // does not — which is how this shipped past three rounds of research.
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("ourwhisper-update-\(UUID().uuidString)", isDirectory: true)

        // `-mountpoint` rather than parsing where it landed: there is no plist to read, no CRC
        // line to skip, and no `/tmp` against `/private/tmp` to normalise. hdiutil creates the
        // directory itself.
        try await shell("/usr/bin/hdiutil", [
            "attach", image.path(percentEncoded: false),
            "-nobrowse", "-readonly", "-noautoopen", "-noverify",
            "-mountpoint", mount.path(percentEncoded: false), "-quiet",
        ])

        // Detached by hand on both paths rather than from a `defer`. A `defer` that spawns the
        // detach cannot be waited on, and on the success path it races a process that is about to
        // exit — losing that race leaves the image mounted for the rest of the login session.
        do {
            let staged = try await copy(from: mount, as: name, into: staging)
            try await shell("/usr/bin/hdiutil", ["detach", mount.path(percentEncoded: false), "-force", "-quiet"])
            try? FileManager.default.removeItem(at: mount)
            return staged
        } catch {
            _ = try? await shell("/usr/bin/hdiutil", ["detach", mount.path(percentEncoded: false), "-force", "-quiet"])
            try? FileManager.default.removeItem(at: mount)
            throw error
        }
    }

    private static func copy(from mount: URL, as name: String, into staging: URL) async throws -> URL {
        // Found in the image rather than assumed to match the installed bundle's filename. The DMG
        // always contains `OurWhisper.app`; the copy on disk is whatever the user called it, and
        // Finder's "Keep Both" alone produces `OurWhisper 2.app`. Looking for that name inside the
        // image would fail every renamed installation, after the whole download, with a message
        // blaming the release.
        let contents = try FileManager.default.contentsOfDirectory(
            at: mount,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let apps = contents.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let source = apps.first else { throw Failure.noAppInImage(apps.count) }

        let staged = staging.appendingPathComponent(name, isDirectory: true)
        try await shell("/usr/bin/ditto", [source.path(percentEncoded: false), staged.path(percentEncoded: false)])

        // A download made with `URLSession` carries no quarantine flag — only `com.apple.provenance`
        // — so on the path this code actually takes there is nothing here to remove. It is done
        // anyway because the flag is inherited on the way *out* of a disk image, invisibly: a file
        // inside a quarantined image shows no attribute at all and acquires one when it is copied.
        // A quarantined self-signed bundle is not warned about, it is killed on launch, which
        // would present as the app simply never coming back.
        _ = try? await shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path(percentEncoded: false)])
        return staged
    }

    @discardableResult
    private static func shell(_ path: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw Failure.commandFailed((path as NSString).lastPathComponent, text)
            }
            return text
        }.value
    }

    // MARK: - Restarting

    /// The flag the new copy is launched with, carrying the pid of the copy it is replacing.
    nonisolated static let awaitingPIDFlag = "--awaiting-pid"

    /// Starts the freshly installed app, and does not return until something is running.
    ///
    /// **`open -n`, and the `-n` is the whole thing.** Plain `open` on a bundle whose app is
    /// already running does not launch anything — LaunchServices matches the running instance by
    /// bundle identifier and merely activates it — and it exits 0 while doing so, so a guard that
    /// checks whether the spawn succeeded never fires. Measured three times out of three: the
    /// successor never started, the old copy terminated on a successful-looking spawn, and the
    /// Mac was left with no OurWhisper running at all. `scripts/install.sh` gets away with plain
    /// `open` only because it force-quits the app before installing, which an app cannot do to
    /// itself and still be around to call `open`.
    ///
    /// `-n` closes the case where `open` succeeds and starts nothing. This waits for `open` to
    /// exit and then looks for the successor by hand, which closes the other one: `open` reports a
    /// launch it could not make with a non-zero exit and a line on stderr, and spawning a process
    /// only proves that `/usr/bin/open` started.
    private static func relaunch(_ app: URL) async throws {
        try await shell("/usr/bin/open", [
            "-n", app.path(percentEncoded: false),
            "--args", awaitingPIDFlag, String(ProcessInfo.processInfo.processIdentifier),
        ])

        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        for _ in 0..<50 {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { $0.processIdentifier != mine }
            if !others.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.noSuccessor
    }

    /// Blocks the new copy until the one it replaced has gone.
    ///
    /// `open -n` is the only form that starts anything while an instance is running, so for a
    /// moment there are two — and `AppState.start()` installs a system-wide event tap and loads a
    /// 600 MB model, neither of which wants a twin. Ten seconds and then on regardless: a
    /// successor that refuses to start because the old copy is wedged is a worse outcome than two
    /// event taps for an instant.
    static func waitForPredecessor(arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard let pid = predecessorPID(in: arguments) else { return }
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    nonisolated static func predecessorPID(in arguments: [String]) -> pid_t? {
        guard let flag = arguments.firstIndex(of: awaitingPIDFlag),
              arguments.index(after: flag) < arguments.endIndex,
              let pid = pid_t(arguments[arguments.index(after: flag)]),
              pid > 0
        else { return nil }
        return pid
    }

    // MARK: - Can this copy be replaced at all

    /// Whether the app is somewhere it can be replaced, and what to tell the user when it is not.
    ///
    /// `probingWrite` decides how the writability half is answered. A real write into the bundle's
    /// parent is the only thing that settles it — `access(2)` says yes for directories a copy still
    /// fails in — but it is a side effect, and two screens asking on every appearance would mean
    /// creating and deleting a file in `/Applications` for the rest of the app's life. So the
    /// button asks the cheap way and `perform` asks properly, once, before it spends 12 MB.
    nonisolated static func installability(of bundle: URL, probingWrite: Bool = true) -> Installability {
        // App Translocation runs a quarantined app from a read-only shadow copy, so the path the
        // app can see is not the path anybody installed it to and replacing it achieves nothing.
        if bundle.path(percentEncoded: false).contains("/AppTranslocation/") { return .translocated }

        let parent = bundle.deletingLastPathComponent()
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return .readOnlyVolume
        }

        guard probingWrite else {
            return FileManager.default.isWritableFile(atPath: parent.path(percentEncoded: false))
                ? .ok
                : .notWritable(parent)
        }

        let probe = parent.appendingPathComponent(".ourwhisper-update-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
        } catch {
            return .notWritable(parent)
        }
        try? FileManager.default.removeItem(at: probe)
        return .ok
    }

    enum Installability: Equatable, Sendable {
        case ok
        case translocated
        case readOnlyVolume
        case notWritable(URL)

        var refusal: String? {
            switch self {
            case .ok:
                nil
            case .translocated:
                "macOS is running this copy from a temporary read-only location, so it cannot replace itself. Move OurWhisper to Applications and open it from there."
            case .readOnlyVolume:
                "This copy is running from a read-only disk. Drag OurWhisper to Applications and open it from there."
            case .notWritable(let parent):
                "This account cannot write to \(parent.path(percentEncoded: false)), so the update cannot be installed there. Ask an administrator, or install to your own Applications folder."
            }
        }
    }

    // MARK: - Failures

    enum Failure: LocalizedError {
        case adHoc
        case refused(String)
        case busy
        case noDiskImage
        case noChecksums
        case noChecksumForImage(String)
        case checksumMismatch
        case truncated(expected: Int64, got: Int64)
        case noAppInImage(Int)
        case noSuccessor
        case github(Int)
        case commandFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .adHoc:
                "This build is ad-hoc signed, so no update can inherit its Accessibility permission. Install with scripts/install.sh instead."
            case .refused(let reason):
                reason
            case .busy:
                "OurWhisper was busy dictating, so it did not restart itself. Nothing was installed; press Update again."
            case .noDiskImage:
                "That release has no disk image to install. Open the release notes and download it by hand."
            case .noChecksums:
                "That release has no SHA256SUMS to check the download against, so it was not installed. Open the release notes and download it by hand."
            case .noChecksumForImage(let name):
                "SHA256SUMS has no entry for \(name), so the download could not be checked. Nothing was installed."
            case .checksumMismatch:
                "The download does not match its published checksum. Nothing was installed; try again."
            case .truncated(let expected, let got):
                "The download stopped early — \(got) bytes of \(expected). Nothing was installed; try again."
            case .noAppInImage(0):
                "The downloaded disk image has no app in it. Nothing was installed."
            case .noAppInImage(let count):
                "The downloaded disk image has \(count) apps in it, so there is no telling which one to install. Nothing was installed."
            case .noSuccessor:
                "The update is installed, but OurWhisper could not restart itself. Quit it and open it again to finish."
            case .github(403), .github(429):
                "GitHub is rate-limiting downloads from this network. Nothing was installed; try again in a few minutes."
            case .github(let status):
                "GitHub answered \(status) for the download. Nothing was installed; try again later."
            case .commandFailed(let tool, let output):
                output.isEmpty ? "\(tool) failed while installing the update." : "\(tool) failed while installing the update: \(output)"
            }
        }
    }
}
