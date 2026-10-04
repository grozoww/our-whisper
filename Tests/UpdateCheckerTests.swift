import Foundation
import Testing

@testable import OurWhisper

@Suite("Update checking")
struct UpdateCheckerTests {
    // MARK: - Version comparison

    @Test("Versions compare numerically, not lexically", arguments: [
        ("1.0.0", "0.9.9", true),
        ("0.10.0", "0.9.0", true),   // the one a string compare gets backwards
        ("0.2.0", "0.10.0", false),
        ("1.2.3", "1.2.3", false),
        ("1.2", "1.2.0", false),     // missing components are zero
        ("1.2.1", "1.2", true),
        ("v1.0.1", "1.0.0", true),   // a leading v is noise
    ])
    func comparesVersions(candidate: String, current: String, expected: Bool) {
        #expect(UpdateChecker.isVersion(candidate, newerThan: current) == expected)
    }

    @Test("A build-from-main tag compares as the version it carries")
    func comparesBuildFromMainTag() {
        // `release-1.0.8-71f957b` is the tag almost every shipped build has. It used to parse as
        // no version at all — 1.0.8 compared as 0.0.0 — so the newest release on offer read as
        // older than whatever the user was already running.
        #expect(UpdateChecker.isVersion("release-1.0.8-71f957b", newerThan: "1.0.5"))
        #expect(!UpdateChecker.isVersion("release-1.0.5-5201edd", newerThan: "1.0.8"))
    }

    @Test("A tag with no version in it never reads as newer", arguments: ["build-7", "latest", "main"])
    func tagWithoutAVersion(tag: String) {
        // A build from another branch is tagged `build-<run number>`. Reading that 7 as a major
        // version would offer everyone version 7 and hand them a downgrade.
        #expect(!UpdateChecker.isVersion(tag, newerThan: "1.0.5"))
    }

    @Test("A pre-release suffix does not make a version newer")
    func ignoresPreReleaseSuffix() {
        // 1.0.0-beta.1 and 1.0.0 must not read as an upgrade in either direction here; the
        // pre-release filter in `parse` is what keeps betas out.
        #expect(!UpdateChecker.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
    }

    // MARK: - Parsing

    private func release(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = [
            "tag_name": "v0.2.0",
            "name": "Modes and history",
            "body": "Notes",
            "html_url": "https://github.com/grozoww/our-whisper/releases/tag/v0.2.0",
            "published_at": "2026-01-15T10:00:00Z",
            "draft": false,
            "prerelease": false,
        ]
        object.merge(overrides) { _, new in new }
        return object
    }

    private func releaseJSON(_ overrides: [String: Any] = [:]) -> Data {
        try! JSONSerialization.data(withJSONObject: release(overrides))
    }

    /// The shape the app actually receives: GitHub's releases list, in whatever order it feels
    /// like. Fixtures here are deliberately not sorted — a sorted one passes even when the code
    /// reads the list positionally, which is exactly how that bug survived a test called
    /// "the newest finished release is the one offered".
    private func releaseListJSON(_ releases: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: releases)
    }

    @Test("A published release parses, with the v stripped")
    func parsesRelease() throws {
        let release = try #require(UpdateChecker.parse(releaseJSON()))
        #expect(release.version == "0.2.0")
        #expect(release.title == "Modes and history")
        #expect(release.publishedAt != nil)
    }

    @Test("A build from main parses to the version in its tag")
    func parsesBuildFromMainTag() throws {
        let release = try #require(UpdateChecker.parse(releaseJSON(["tag_name": "release-1.0.8-71f957b"])))
        #expect(release.version == "1.0.8")
    }

    @Test("Drafts and pre-releases are not offered", arguments: ["draft", "prerelease"])
    func rejectsUnfinishedReleases(flag: String) {
        // Someone running the shipped app should never be nudged onto a build the maintainer has
        // not finished publishing.
        #expect(UpdateChecker.parse(releaseJSON([flag: true])) == nil)
    }

    @Test("A release with no name falls back to its tag")
    func fallsBackToTag() throws {
        let release = try #require(UpdateChecker.parse(releaseJSON(["name": ""])))
        #expect(release.title == "v0.2.0")
    }

    @Test("The newest finished release in the list is the one offered")
    func picksNewestFinishedRelease() throws {
        // A build from a branch is a prerelease and can sit anywhere in the list. Taking the first
        // entry regardless is what would offer everyone a build nobody merged — and the finished
        // entries are out of order here so that taking the first *finished* one fails too.
        let data = releaseListJSON([
            release(["tag_name": "release-1.0.9-abc1234", "prerelease": true]),
            release(["tag_name": "v1.0.6"]),
            release(["tag_name": "v1.0.8", "draft": true]),
            release(["tag_name": "v1.0.7"]),
        ])
        let found = try #require(UpdateChecker.parse(data))
        #expect(found.version == "1.0.7")
    }

    @Test("The release list is not read positionally")
    func ignoresTheOrderGitHubReturns() throws {
        // This is the real `GET /releases` response for this repository, tags and flags verbatim.
        // GitHub documents no order and returns none: 1.0.9 comes back ahead of 1.0.12, 1.0.11 and
        // 1.0.10, matching neither `id`, `created_at` nor `published_at`. Reading the first
        // finished entry told everyone on 1.0.11 that 1.0.9 was the newest release, which is not
        // newer, so the app reported itself up to date through four consecutive releases.
        let data = releaseListJSON([
            release(["tag_name": "release-1.0.9-38ea901"]),
            release(["tag_name": "release-1.0.8-71f957b"]),
            release(["tag_name": "release-1.0.12-0c56a0f"]),
            release(["tag_name": "release-1.0.11-345a4a1"]),
            release(["tag_name": "release-1.0.10-9a20a36"]),
            release(["tag_name": "release-1.0.7-bc71101", "prerelease": true]),
            release(["tag_name": "build-10", "prerelease": true]),
        ])

        let found = try #require(UpdateChecker.parse(data))
        #expect(found.version == "1.0.12")
        #expect(UpdateChecker.isVersion(found.version, newerThan: "1.0.11"))
    }

    @Test("Ten sorts above nine, in the list as well as in the comparison")
    func picksTenOverNine() throws {
        // The same trap `scripts/install.sh` needs `sort -V` for: plain string order puts 1.0.9
        // above 1.0.10, so a list whose highest version is a two-digit patch is the case that
        // catches a comparison done on strings.
        let data = releaseListJSON([
            release(["tag_name": "v1.0.9"]),
            release(["tag_name": "v1.0.10"]),
        ])
        let found = try #require(UpdateChecker.parse(data))
        #expect(found.version == "1.0.10")
    }

    @Test("A list with nothing finished in it offers nothing")
    func listOfOnlyPrereleases() {
        let data = releaseListJSON([
            release(["tag_name": "release-1.0.9-abc1234", "prerelease": true]),
            release(["tag_name": "release-1.0.8-def5678", "prerelease": true]),
        ])
        #expect(UpdateChecker.parse(data) == nil)
    }

    @Test("A repository whose every release is a prerelease reads as up to date, not as an error")
    @MainActor
    func treatsUnfinishedReleasesAsUpToDate() async {
        // A repository whose only builds are from branches. Reporting that as a failure — or as
        // "no usable tag_name" — is what made the Check button look broken.
        let data = releaseListJSON([release(["tag_name": "release-99.0.0-abc1234", "prerelease": true])])
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: data))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .upToDate = state else {
            Issue.record("expected up to date, got \(state)")
            return
        }
    }

    @Test("An empty releases list reads as up to date")
    @MainActor
    func treatsEmptyListAsUpToDate() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: Data("[]".utf8)))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .upToDate = state else {
            Issue.record("expected up to date, got \(state)")
            return
        }
    }

    @Test("A response that is not JSON is reported as a failure")
    @MainActor
    func reportsUnreadableResponse() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: Data("<html>nope</html>".utf8)))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .failed = state else {
            Issue.record("expected a failure state, got \(state)")
            return
        }
    }

    @Test("Malformed JSON returns nil rather than throwing")
    func handlesGarbage() {
        #expect(UpdateChecker.parse(Data("not json".utf8)) == nil)
        #expect(UpdateChecker.parse(Data("{}".utf8)) == nil)
    }

    // MARK: - Behaviour

    @Test("A newer release is reported as available")
    @MainActor
    func reportsAvailableRelease() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: releaseListJSON([release(["tag_name": "v99.0.0"])])))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .available(let release) = state else {
            Issue.record("expected an available release, got \(state)")
            return
        }
        #expect(release.version == "99.0.0")
    }

    @Test("A skipped version is not offered again")
    @MainActor
    func honoursSkippedVersion() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: releaseListJSON([release(["tag_name": "v99.0.0"])])))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check(skippedVersion: "99.0.0")
        guard case .upToDate = state else {
            Issue.record("a skipped version should not be offered, got \(state)")
            return
        }
    }

    @Test("Checking manually overrides a skip")
    @MainActor
    func forceOverridesSkip() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: releaseListJSON([release(["tag_name": "v99.0.0"])])))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check(skippedVersion: "99.0.0", force: true)
        guard case .available = state else {
            Issue.record("pressing Check should find a skipped version, got \(state)")
            return
        }
    }

    @Test("The request carries no identifying information")
    @MainActor
    func sendsNothingIdentifying() async throws {
        // README.md promises this check is not telemetry. The promise is only kept if the request
        // says nothing about the user or this Mac.
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: releaseJSON()))])
        let checker = UpdateChecker(http: stub)
        _ = await checker.check()

        let request = stub.requests[0]
        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.query == nil)
        // URLSession fills these two in by itself if they are left alone: a User-Agent carrying
        // the app version and the exact macOS build, and an Accept-Language carrying the user's
        // region. They cannot be removed, only replaced with something every user sends.
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "OurWhisper")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
    }

    @Test("The check asks for the latest release, not for a page of the list")
    @MainActor
    func asksForTheLatestRelease() async throws {
        // Builds from other branches are prereleases and pile up in the list. A page of 30 of those
        // pushes the newest finished release off it, and the check then says "up to date" with an
        // update waiting. The latest-release endpoint has no page to fall off, and skips
        // prereleases itself. The stub matches on a substring, so only the request can say which
        // one the code asked for.
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: releaseJSON()))])
        let checker = UpdateChecker(http: stub)
        _ = await checker.check()

        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/repos/grozoww/our-whisper/releases/latest")
    }

    // MARK: - Assets

    private func asset(_ name: String, size: Int = 12_014_558, state: String = "uploaded") -> [String: Any] {
        [
            "name": name,
            "state": state,
            "size": size,
            "browser_download_url": "https://github.com/grozoww/our-whisper/releases/download/release-1.0.15-68c910d/\(name)",
        ]
    }

    @Test("The disk image and its checksums come off the release that carries them")
    func findsAssets() throws {
        // Both taken from the same release object, never searched for separately: install.sh used
        // to find them independently and could pair an image with another release's checksums,
        // which then matched nothing and skipped the check without saying so.
        let found = try #require(UpdateChecker.parse(releaseJSON([
            "assets": [asset("OurWhisper-1.0.15-unnotarized.dmg"), asset("SHA256SUMS", size: 100)],
        ])))

        #expect(found.dmg?.name == "OurWhisper-1.0.15-unnotarized.dmg")
        #expect(found.dmg?.size == 12_014_558)
        #expect(found.checksums?.lastPathComponent == "SHA256SUMS")
    }

    @Test("An asset GitHub has not finished receiving is not offered")
    func ignoresAssetsStillUploading() throws {
        // Its download URL 404s, so offering it fails a download the user pressed a button for.
        let found = try #require(UpdateChecker.parse(releaseJSON([
            "assets": [asset("OurWhisper-1.0.15-unnotarized.dmg", state: "starter"), asset("SHA256SUMS", size: 100)],
        ])))
        #expect(found.dmg == nil)
    }

    @Test("A release with no assets still parses and still offers its notes")
    func parsesReleaseWithoutAssets() throws {
        // Releases from before SHA256SUMS existed have none, and a release with nothing to install
        // is still worth telling the user about — the banner has a link either way.
        let found = try #require(UpdateChecker.parse(releaseJSON()))
        #expect(found.dmg == nil)
        #expect(found.checksums == nil)
        #expect(found.url.absoluteString.hasSuffix("v0.2.0"))
    }

    @Test("The disk image is chosen, not taken in the order GitHub listed it")
    func choosesTheDiskImage() throws {
        // `package.sh` names the image for the way it was signed, and GitHub documents no order
        // for `assets` any more than it does for the releases list — the mistake that already cost
        // this project four silent releases. A notarized build is what a user wants; the ad-hoc
        // `-unsigned` one can never satisfy the running app's requirement, so offering it would
        // only ever produce a refusal.
        let found = try #require(UpdateChecker.parse(releaseJSON([
            "assets": [
                asset("OurWhisper-1.0.15-unsigned.dmg"),
                asset("OurWhisper-1.0.15-unnotarized.dmg"),
                asset("OurWhisper-1.0.15.dmg"),
            ],
        ])))
        #expect(found.dmg?.name == "OurWhisper-1.0.15.dmg")
    }

    @Test("An ad-hoc build is never offered, even when it is the only image there")
    func neverOffersAnUnsignedImage() throws {
        let found = try #require(UpdateChecker.parse(releaseJSON([
            "assets": [asset("OurWhisper-1.0.15-unsigned.dmg"), asset("SHA256SUMS", size: 100)],
        ])))
        #expect(found.dmg == nil)
    }

    @Test("Assets that are neither the image nor the checksums are ignored")
    func ignoresOtherAssets() throws {
        let found = try #require(UpdateChecker.parse(releaseJSON([
            "assets": [asset("INSTALL.md", size: 2_000), asset("OurWhisper-1.0.15-unnotarized.dmg")],
        ])))
        #expect(found.dmg?.name == "OurWhisper-1.0.15-unnotarized.dmg")
        #expect(found.checksums == nil)
    }

    @Test("A repository with no releases yet is not an error")
    @MainActor
    func treatsMissingReleasesAsUpToDate() async {
        // Before the first release, GitHub answers 404. Reporting that as a failure would tell
        // every early user their update check is broken.
        let stub = StubHTTPClient(script: [("/releases", .init(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8)))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .upToDate = state else {
            Issue.record("a repository with no releases should read as up to date, got \(state)")
            return
        }
    }

    @Test("A network failure is reported, not swallowed")
    @MainActor
    func reportsFailure() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 503, body: Data()))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .failed = state else {
            Issue.record("expected a failure state, got \(state)")
            return
        }
    }
}
