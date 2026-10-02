import Foundation
import Observation
import OSLog

/// Asks GitHub whether there is a newer release.
///
/// This is the *only* outbound request the app makes without the user starting a dictation, and
/// `README.md` promises it is not telemetry. That promise is kept by what is not here: no
/// identifier, no version reported to the server, no analytics endpoint. It is an unauthenticated
/// GET of a public JSON file — the same request `curl` would make — and the comparison happens on
/// this machine. Turning it off in Configuration means the app makes no unattended requests at all.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(Release)
        case failed(String)
    }

    struct Release: Equatable, Sendable {
        let version: String
        let title: String
        let notes: String
        let url: URL
        let publishedAt: Date?
        /// The disk image to install, and the file carrying its checksum.
        ///
        /// Both optional, and they have to be: releases from before `SHA256SUMS` existed have no
        /// checksum, an asset can still be uploading, and a release with neither is still worth
        /// showing — the banner has release notes to offer whether or not the app can install it.
        /// `UpdateInstaller` refuses without both rather than guessing at one.
        let dmg: Asset?
        let checksums: URL?
    }

    struct Asset: Equatable, Sendable {
        let name: String
        let url: URL
        /// What GitHub says the file weighs. Checked before the checksum, because comparing two
        /// numbers is free and hashing 12 MB is not.
        let size: Int64
    }

    /// The list of releases — deliberately *not* `/releases/latest`, and deliberately not read in
    /// the order it arrives in; see `newestFinishedRelease`.
    ///
    /// That endpoint only ever answers with the one release GitHub itself considers latest, and it
    /// skips prereleases entirely. Every release used to be marked a prerelease, so it answered
    /// 404 and this type read that as "up to date" — the check found nothing, for ever. A build
    /// from main is a finished release now, but a rehearsal run is still a prerelease, so reading
    /// the whole list and picking the highest finished version out of it stays the answer that
    /// cannot go quiet on us. `scripts/install.sh` reads this same list for the same reason.
    ///
    /// No query string, so the request stays something anyone can verify says nothing about them —
    /// see `sendsNothingIdentifying`. GitHub's default page of 30 is far more than enough.
    private static let endpoint = URL(string: "https://api.github.com/repos/grozoww/our-whisper/releases")!

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "update")
    private let http: any HTTPClient

    private(set) var state: State = .idle

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// What went wrong reaching GitHub, said the way GitHub failures actually happen.
    ///
    /// `HTTPError.from` maps 401 and 403 to "The API key was rejected. Check it in Configuration",
    /// which is right for a cloud speech provider and wrong here twice over: this request carries
    /// no key at all, and a 403 from GitHub is its rate limit for unauthenticated callers, which
    /// clears by itself. Telling someone to check a key they have never had is worse than telling
    /// them nothing.
    enum Failure: LocalizedError {
        case github(Int)

        var errorDescription: String? {
            switch self {
            case .github(403), .github(429):
                "GitHub is rate-limiting update checks from this network. Try again in a few minutes."
            case .github(let status):
                "GitHub answered \(status) when asked for the releases list. Try again later."
            }
        }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Dismisses the current banner. Separate from `check` so the UI does not need write access to
    /// `state`, which only this type is allowed to set.
    func dismissAvailableRelease() {
        guard case .available = state else { return }
        state = .upToDate(checkedAt: Date())
    }

    /// Checks now. `skippedVersion` is honoured so a release the user dismissed does not come back
    /// on every launch — they can still find it with the manual button, which passes `force`.
    @discardableResult
    func check(skippedVersion: String? = nil, force: Bool = false) async -> State {
        state = .checking

        var request = Self.anonymousRequest(Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await http.send(request)

            // GitHub answers 404 when a repository has no published releases at all. That is the
            // normal state before the first release, not a failure, and showing the user "404 Not
            // Found" for it would be alarming and wrong.
            if response.statusCode == 404 {
                state = .upToDate(checkedAt: Date())
                return state
            }

            guard (200..<300).contains(response.statusCode) else {
                throw Failure.github(response.statusCode)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                throw HTTPError.malformedResponse("the releases list was not JSON")
            }

            // A readable list with nothing finished in it is an ordinary state — a repository
            // whose only builds are rehearsals — and not the same thing as a response we could not
            // read. Only the latter is worth telling the user about.
            guard let release = Self.newestFinishedRelease(in: json) else {
                state = .upToDate(checkedAt: Date())
                log.info("Update check: no finished release published yet")
                return state
            }

            let isNewer = Self.isVersion(release.version, newerThan: Self.currentVersion)
            let wasSkipped = !force && release.version == skippedVersion

            state = (isNewer && !wasSkipped) ? .available(release) : .upToDate(checkedAt: Date())
            log.info("Update check: latest \(release.version, privacy: .public), running \(Self.currentVersion, privacy: .public)")
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }

        return state
    }

    // MARK: - Parsing
    //
    // Parsing and version comparison are pure functions of their input, so they are `nonisolated`
    // — the surrounding type is `@MainActor` for its observable state, and there is no reason for
    // a string comparison to need the main thread to run or a test to reach it.

    /// Takes either the releases list or a single release object, so the same parsing covers the
    /// list endpoint above and a hand-fetched release.
    nonisolated static func parse(_ data: Data) -> Release? {
        (try? JSONSerialization.jsonObject(with: data)).flatMap(newestFinishedRelease(in:))
    }

    /// The finished release carrying the highest version — deliberately *not* the first one listed.
    ///
    /// GitHub documents no order for `GET /releases`, and it does not come back newest first. The
    /// real response for this repository puts `release-1.0.9-38ea901` ahead of 1.0.12, 1.0.11 and
    /// 1.0.10, in an order matching neither `id`, `created_at` nor `published_at`. Taking the first
    /// finished entry therefore told a user on 1.0.11 that the newest release was 1.0.9 — which is
    /// not newer, so the check answered "up to date" and went on doing so for every release after
    /// it. `scripts/install.sh` had the identical bug and fixes it with `sort -V`; this is the
    /// same fix on the app side, and it is why the version has to be parsed before anything is
    /// compared rather than after a position is chosen.
    nonisolated static func newestFinishedRelease(in json: Any) -> Release? {
        if let list = json as? [[String: Any]] {
            return list.compactMap(release(from:))
                .max { isVersion($1.version, newerThan: $0.version) }
        }
        return (json as? [String: Any]).flatMap(release(from:))
    }

    nonisolated private static func release(from json: [String: Any]) -> Release? {
        guard let tag = json["tag_name"] as? String,
              let urlString = json["html_url"] as? String,
              let url = URL(string: urlString)
        else { return nil }

        // Drafts and pre-releases are not offered. Someone running the shipped app should not be
        // nudged onto a build the maintainer has not finished.
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }

        let published = (json["published_at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }

        let (dmg, checksums) = assets(in: json)

        return Release(
            version: normalise(tag),
            title: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            notes: json["body"] as? String ?? "",
            url: url,
            publishedAt: published,
            dmg: dmg,
            checksums: checksums
        )
    }

    /// The version numbers a tag carries, whatever else is wrapped around them.
    ///
    /// Tags come in two shapes here: `v1.2.3` for a version someone cut, and
    /// `release-1.2.3-a1b2c3d` for a build from main — and the second one is what almost everybody
    /// is actually running. Stripping a leading `v` handled the first and left the second with a
    /// word in front of the numbers, which `components` reads as no version at all. 1.0.8 then
    /// compared as 0.0.0, and nobody was ever offered an update. Taking the first run of
    /// dot-separated digits handles both shapes and the `-<sha>` on the end at the same time.
    ///
    /// A dot is required, so `build-7` — what a rehearsal run is tagged — does not read as version
    /// 7 and leapfrog every real release.
    nonisolated static func normalise(_ tag: String) -> String {
        let value = tag.trimmingCharacters(in: .whitespaces)
        guard let numbers = value.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else {
            return value
        }
        return String(value[numbers])
    }

    /// Numeric component-wise comparison.
    ///
    /// Not a string compare: `"0.10.0" < "0.9.0"` lexically, which would tell everyone on 0.10 to
    /// downgrade. Missing components count as zero, so `1.2` and `1.2.0` are the same version.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: current)

        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    nonisolated private static func components(of version: String) -> [Int] {
        normalise(version)
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .prefix { Int($0) != nil }
            .compactMap { Int($0) }
    }

    // MARK: - What a release carries

    /// A GET that says nothing about this Mac.
    ///
    /// Left alone, `URLSession` fills in two headers of its own: `User-Agent` becomes
    /// `OurWhisper/1.0.15 CFNetwork/… Darwin/25.6.0` — the app version and the exact macOS build —
    /// and `Accept-Language` becomes whatever region the user set. Neither can be removed, so both
    /// are replaced with constants that are identical for every user. The Configuration screen
    /// promises "nothing about you or this Mac is sent"; this is what makes that true rather than
    /// nearly true. `sendsNothingIdentifying` and `sendsNothingIdentifyingWhenDownloading` are
    /// what keep it so, and both assert on the request the code sent rather than on one the test
    /// built for itself — which is the only version of that test that can fail.
    nonisolated static func anonymousRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("OurWhisper", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 15
        return request
    }

    /// The DMG and the `SHA256SUMS` beside it, out of a release's `assets` array.
    ///
    /// Taken from the same release object as the download rather than searched for separately:
    /// `scripts/install.sh` used to find the two independently and could pair a disk image with
    /// another release's checksums, which then matched nothing and skipped the check in silence.
    ///
    /// `state` is `uploaded` once GitHub actually has the bytes; anything else has a URL that 404s.
    /// A missing `state` counts as uploaded, so a hand-made fixture does not have to carry one.
    nonisolated static func assets(in json: [String: Any]) -> (dmg: Asset?, checksums: URL?) {
        let uploaded = ((json["assets"] as? [[String: Any]]) ?? [])
            .filter { ($0["state"] as? String ?? "uploaded") == "uploaded" }

        func url(of asset: [String: Any]) -> URL? {
            (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        }

        // Chosen, not taken. GitHub documents no order for `assets` either, and reading a GitHub
        // list positionally is the mistake that already cost this project four silent releases —
        // see `newestFinishedRelease`. `package.sh` gives the image one of three names depending on
        // how it was signed, and the ranking below is that same order of preference: a notarized
        // build over an unnotarized one, and never the ad-hoc `-unsigned` build, which cannot
        // satisfy the running app's designated requirement and would only ever be refused.
        let dmg = uploaded
            .compactMap { asset -> Asset? in
                guard let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                      !name.hasSuffix("-unsigned.dmg"), let url = url(of: asset)
                else { return nil }
                return Asset(name: name, url: url, size: (asset["size"] as? NSNumber)?.int64Value ?? 0)
            }
            .min { (rank($0.name), $0.name) < (rank($1.name), $1.name) }

        let checksums = uploaded.first { ($0["name"] as? String) == "SHA256SUMS" }.flatMap(url(of:))
        return (dmg, checksums)
    }

    /// Lower is preferred. `package.sh`'s three signing paths, in the order a user wants them.
    nonisolated private static func rank(_ name: String) -> Int {
        name.hasSuffix("-unnotarized.dmg") ? 1 : 0
    }
}
