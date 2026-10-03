import Foundation
import Security

/// Whether a bundle on disk was signed with the same key as the app that is running.
///
/// This is the only thing standing between "a file arrived over HTTPS" and "that file is now the
/// app", and everything else that looks like a check is weaker than it appears. `SHA256SUMS` is
/// served from the same GitHub release as the disk image, so it catches a truncated download and
/// nothing else. Gatekeeper never gets a look: a `URLSession` download is not quarantined, so
/// there is no assessment to fail. TLS authenticates GitHub, not the publisher.
///
/// The requirement is read from the *running* app rather than written down here, and that is what
/// makes it a pin rather than a formality. A release build's designated requirement is
/// `identifier "com.grozoww.ourwhisper" and certificate leaf = H"5b6de378…"` — the certificate, by
/// fingerprint. Checking a candidate against *its own* designated requirement instead would pass
/// every bundle ever signed, because a self-signed certificate's requirement is generated from
/// whichever key signed it: a build signed with the "OurWhisper Dev" certificate satisfies its own
/// requirement perfectly and fails this one.
///
/// It is also, exactly, the condition under which the Accessibility grant survives. macOS records
/// the grant against the bundle identifier and the designated requirement, so a bundle that
/// satisfies this one inherits the permission the user already gave. One check answers both
/// questions, which is why there is only one.
enum BundleSignature {
    /// The running app's designated requirement, in the text form `SecRequirementCreateWithString`
    /// reads back.
    ///
    /// A string rather than the `SecRequirement` itself so it can cross into the detached task
    /// that does the verifying — a CF object cannot, and re-creating it from its own text form on
    /// the other side is lossless.
    ///
    /// **Read this before anything is written to disk.** `SecCodeCopySelf` resolves through the
    /// bundle's path, and after the swap that path holds the incoming app — so a requirement read
    /// afterwards is the *new* build's, and the check then compares the new build against itself
    /// and cannot fail.
    static func runningRequirement() throws -> String {
        var code: SecCode?
        try check(SecCodeCopySelf([], &code), "read this app's own code signature")
        guard let code else { throw Failure.unreadable }

        var statik: SecStaticCode?
        try check(SecCodeCopyStaticCode(code, [], &statik), "read this app's signature from disk")
        guard let statik else { throw Failure.unreadable }

        var requirement: SecRequirement?
        try check(SecCodeCopyDesignatedRequirement(statik, [], &requirement), "read this app's designated requirement")
        guard let requirement else { throw Failure.unreadable }

        var text: CFString?
        try check(SecRequirementCopyString(requirement, [], &text), "read this app's designated requirement")
        guard let text else { throw Failure.unreadable }
        return text as String
    }

    /// Whether *any* other build could ever satisfy this requirement.
    ///
    /// An ad-hoc signature — a plain `xcodebuild` — has the requirement
    /// `cdhash H"…"`, which is one exact binary. No update can satisfy it, so a build signed that
    /// way cannot update itself into anything: the grant is lost whatever happens, and the honest
    /// answer is to refuse and point at `scripts/install.sh` rather than to install and let
    /// dictation stop working with no error at all.
    ///
    /// Judged on the requirement's shape, not on whether a word appears in it. A plain
    /// `contains("certificate")` is wrong in both directions and both are requirements
    /// `SecRequirementCopyString` will really hand back: `identifier "com.example.certificate" and
    /// cdhash H"…"` is a cdhash pin that answers yes, and `identifier "…" and anchor apple generic`
    /// is satisfiable by every later build and answers no. Quoted literals are dropped first so an
    /// identifier cannot vote, `cdhash` anywhere is disqualifying, and either a certificate or an
    /// anchor clause is what makes a requirement one a future build can meet.
    ///
    /// Pure, so the decision is tested rather than inferred from a build somebody made.
    nonisolated static func namesACertificate(_ requirement: String) -> Bool {
        let unquoted = requirement
            .split(separator: "\"", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.offset.isMultiple(of: 2) }
            .map(\.element)
            .joined(separator: " ")

        guard !unquoted.contains("cdhash") else { return false }
        return unquoted.contains("certificate") || unquoted.contains("anchor")
    }

    /// Throws unless the bundle at `url` satisfies `requirement`.
    ///
    /// One call does all of it: the signature, the executable, every sealed resource, and the
    /// requirement. Reading the candidate's own designated requirement and comparing the two
    /// strings would compare two claims a tampered bundle makes about itself — measured, a bundle
    /// with a byte appended to `AppIcon.icns` reports a designated requirement identical to the
    /// genuine one, and only this call rejects it.
    static func verify(_ url: URL, satisfies requirement: String) throws {
        var parsed: SecRequirement?
        try check(SecRequirementCreateWithString(requirement as CFString, [], &parsed), "read this app's designated requirement")
        guard let parsed else { throw Failure.unreadable }

        var candidate: SecStaticCode?
        try check(
            SecStaticCodeCreateWithPath(url as CFURL, [], &candidate),
            "read the downloaded app's signature"
        )
        guard let candidate else { throw Failure.unreadable }

        // `kSecCSDoNotValidateResources` — which `kSecCSBasicValidateOnly` implies — saves about a
        // millisecond and returns success on a bundle whose sealed resources were swapped. It is
        // not on this list for that reason. `kSecCSCheckNestedCode` is free today because the app
        // embeds no frameworks; it is here so it is already on the day one arrives.
        let flags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks
            | kSecCSRestrictSidebandData
        )

        let status = SecStaticCodeCheckValidity(candidate, flags, parsed)
        guard status == errSecSuccess else {
            // The two outcomes need different sentences, because the user can do something about
            // one of them and nothing about the other.
            throw status == errSecCSReqFailed ? Failure.wrongSigner : Failure.damaged(status)
        }
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case wrongSigner
        case damaged(OSStatus)
        case osStatus(OSStatus, String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "Could not read this app's own code signature, so the download cannot be checked against it."
            case .wrongSigner:
                "The download is signed with a different key than this copy of OurWhisper. It was not installed. Download it yourself from the releases page if you meant to switch."
            case .damaged(let status):
                // The code is in the sentence because a dozen distinct errSecCS… failures all read
                // as "damaged" to a user, and the number is the only thing that tells the person
                // reading the bug report which one it was.
                "The download's signature does not check out — it is damaged (error \(status)). Nothing was installed; try again."
            case .osStatus(let status, let what):
                "Could not \(what) (error \(status))."
            }
        }
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status != errSecSuccess else { return }
        throw Failure.osStatus(status, what)
    }
}
