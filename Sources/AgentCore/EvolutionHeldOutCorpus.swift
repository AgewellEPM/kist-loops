import Foundation

/// The operator-provisioned private held-out corpus: the missing INPUT that makes parent-relative
/// capability fitness earnable. `EvolutionHeldOutOracle` compares captured streams against expected
/// digests, but nothing loaded those expectations from disk — they existed only in tests. This store
/// loads them from an owner-private directory, freezes their identity, and refuses to leak either the
/// expected bytes/digests or the invocation into any candidate-visible surface.
///
/// It deliberately does NOT execute anything, mint a receipt, install a benchmark backend, or change
/// autonomy readiness. Providing the corpus is a prerequisite for a future host-owned Linux executor;
/// on macOS the paired coordinator still refuses before any case runs (hard containment is unavailable).
///
/// The enum is public but only `availability` is: `load`/`Frozen` expose the internal `Expectation`
/// type, so they stay in-module (the future host backend is in AgentCore). A status surface only needs
/// the bounded, disclosure-free availability probe.
public enum EvolutionHeldOutCorpus {
    static let manifestSchema = "kist.evolution.held-out-corpus.v1"
    static let manifestName = "corpus.json"
    static let maximumManifestBytes = 4 * 1_024 * 1_024
    static let maximumCases = 4_096
    static let maximumArgv = 64
    static let maximumArgumentBytes = 4_096
    static let maximumStdinBytes = 64 * 1_024
    static let minimumTimeoutSeconds = 1
    static let maximumTimeoutSeconds = 900

    enum Error: Swift.Error, LocalizedError, Equatable {
        case unsafeDirectory(String)
        case unsafeManifest(String)
        case malformedManifest(String)
        case invalidCase(caseID: String, reason: String)
        case corpusInsideCandidateRoot(String)
        case emptyCorpus
        case duplicateCase(String)

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory(let detail): return "held-out corpus directory is not owner-private: \(detail)"
            case .unsafeManifest(let detail): return "held-out corpus manifest is not an owned regular file: \(detail)"
            case .malformedManifest(let detail): return "held-out corpus manifest is malformed: \(detail)"
            case .invalidCase(let caseID, let reason): return "held-out corpus case \(caseID) is invalid: \(reason)"
            case .corpusInsideCandidateRoot(let path): return "held-out corpus must live outside every candidate-visible root: \(path)"
            case .emptyCorpus: return "held-out corpus contains no cases"
            case .duplicateCase(let caseID): return "held-out corpus repeats case ID \(caseID)"
            }
        }
    }

    /// Exactly how one held-out case is executed. This is host-only input for a future executor; it must
    /// never enter a candidate prompt, tool root, argv, environment, or archive text. Bounded on every
    /// field so a corpus file cannot smuggle an unbounded launch through the evaluator.
    struct Invocation: Sendable, Equatable {
        let caseID: String
        let argv: [String]
        let stdin: String
        let timeoutSeconds: Int
    }

    /// A frozen corpus: the oracle-graded expectations plus their private invocations, bound by one
    /// digest identical to `EvolutionHeldOutOracle.corpusDigest`. `expectations` and `invocations` share
    /// one sorted case-ID set; the digest covers only the expectations, exactly as the oracle re-derives.
    struct Frozen: Sendable {
        let expectations: [EvolutionHeldOutOracle.Expectation]
        let invocations: [Invocation]
        let corpusDigest: String

        /// The sorted case-ID set both arms must execute. Handy for a backend to plan its runs.
        var caseIDs: [String] { expectations.map(\.caseID) }
    }

    private struct Manifest: Decodable {
        let schema: String
        let cases: [Case]
        struct Case: Decodable {
            let caseID: String
            let argv: [String]
            let stdin: String?
            let timeoutSeconds: Int
            let expectedExitCode: Int32
            let stdoutDigest: String
            let stderrDigest: String
        }
    }

    /// Load and freeze the corpus under `directory`. `forbiddenRoots` are candidate-visible roots (e.g.
    /// the evolution host repo and every worktree): the corpus is refused if it resolves inside one, so a
    /// corpus can never be provisioned somewhere a candidate could read the answers. Fail-closed on every
    /// permission, path, schema, and per-case invariant.
    static func load(directory: String, forbiddenRoots: [String] = []) throws -> Frozen {
        let resolvedCorpus = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        for root in forbiddenRoots {
            let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            if resolvedCorpus == resolvedRoot || resolvedCorpus.hasPrefix(resolvedRoot + "/") {
                throw Error.corpusInsideCandidateRoot(resolvedCorpus)
            }
        }

        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else {
            throw Error.unsafeDirectory("cannot open \(directory) as an owned directory")
        }
        defer { _ = close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(),
              (directoryInfo.st_mode & mode_t(0o077)) == 0 else {
            throw Error.unsafeDirectory("owner-only 0700 directory required")
        }

        let data = try readManifest(directoryFD: directoryFD)
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw Error.malformedManifest(String(describing: error)) }
        guard manifest.schema == manifestSchema else {
            throw Error.malformedManifest("unknown schema \(manifest.schema)")
        }
        guard !manifest.cases.isEmpty else { throw Error.emptyCorpus }
        guard manifest.cases.count <= maximumCases else {
            throw Error.malformedManifest("more than \(maximumCases) cases")
        }

        var expectations: [EvolutionHeldOutOracle.Expectation] = []
        var invocations: [Invocation] = []
        var seen = Set<String>()
        for entry in manifest.cases {
            guard seen.insert(entry.caseID).inserted else { throw Error.duplicateCase(entry.caseID) }
            let expectation: EvolutionHeldOutOracle.Expectation
            do {
                expectation = try EvolutionHeldOutOracle.Expectation(
                    caseID: entry.caseID, expectedExitCode: entry.expectedExitCode,
                    stdoutDigest: entry.stdoutDigest, stderrDigest: entry.stderrDigest)
            } catch {
                throw Error.invalidCase(caseID: entry.caseID, reason: "exit code or expected digests are invalid")
            }
            try validateInvocation(entry)
            expectations.append(expectation)
            invocations.append(Invocation(
                caseID: entry.caseID, argv: entry.argv, stdin: entry.stdin ?? "",
                timeoutSeconds: entry.timeoutSeconds))
        }

        // Freeze exactly as the oracle will re-derive it (sorted, canonical), so a corpus loaded here and
        // a plan built by the backend agree on identity or fail closed — ordering cannot change it.
        let corpusDigest = try EvolutionHeldOutOracle.corpusDigest(expectations)
        let sortedExpectations = expectations.sorted { $0.caseID < $1.caseID }
        let invocationByID = Dictionary(uniqueKeysWithValues: invocations.map { ($0.caseID, $0) })
        let sortedInvocations = sortedExpectations.map { invocationByID[$0.caseID]! }
        return Frozen(expectations: sortedExpectations, invocations: sortedInvocations,
                      corpusDigest: corpusDigest)
    }

    /// Availability probe for a readiness surface. Returns the frozen case count, or a bounded human
    /// reason it is unavailable. Never throws and never discloses expected bytes or invocation detail.
    public static func availability(directory: String, forbiddenRoots: [String] = []) -> (ready: Bool, detail: String) {
        do {
            let frozen = try load(directory: directory, forbiddenRoots: forbiddenRoots)
            return (true, "\(frozen.expectations.count) frozen held-out case(s) · digest \(frozen.corpusDigest.prefix(12))…")
        } catch let error as Error {
            return (false, error.errorDescription ?? "held-out corpus unavailable")
        } catch {
            return (false, "held-out corpus unavailable")
        }
    }

    private static func validateInvocation(_ entry: Manifest.Case) throws {
        guard (1...maximumArgv).contains(entry.argv.count) else {
            throw Error.invalidCase(caseID: entry.caseID, reason: "argv must have 1...\(maximumArgv) elements")
        }
        for argument in entry.argv {
            guard !argument.isEmpty, argument.utf8.count <= maximumArgumentBytes,
                  argument.rangeOfCharacter(from: .newlines) == nil else {
                throw Error.invalidCase(caseID: entry.caseID, reason: "an argv element is empty, oversized, or multi-line")
            }
        }
        guard (entry.stdin ?? "").utf8.count <= maximumStdinBytes else {
            throw Error.invalidCase(caseID: entry.caseID, reason: "stdin exceeds \(maximumStdinBytes) bytes")
        }
        guard (minimumTimeoutSeconds...maximumTimeoutSeconds).contains(entry.timeoutSeconds) else {
            throw Error.invalidCase(caseID: entry.caseID,
                reason: "timeout must be \(minimumTimeoutSeconds)...\(maximumTimeoutSeconds) seconds")
        }
    }

    /// Owner-private, O_NOFOLLOW manifest read matching the archive store's descriptor discipline: a
    /// regular file, owned by us, single hard link, no group/other bits, bounded, same dev/ino before
    /// and after the read.
    private static func readManifest(directoryFD: Int32) throws -> Data {
        var pathInfo = stat()
        guard fstatat(directoryFD, manifestName, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Error.unsafeManifest("\(manifestName) is missing")
        }
        let fd = openat(directoryFD, manifestName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Error.unsafeManifest("cannot open \(manifestName)") }
        defer { _ = close(fd) }
        func validate() throws {
            var descriptorInfo = stat(); var currentPath = stat()
            guard fstat(fd, &descriptorInfo) == 0,
                  fstatat(directoryFD, manifestName, &currentPath, AT_SYMLINK_NOFOLLOW) == 0,
                  (descriptorInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  (currentPath.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  descriptorInfo.st_uid == getuid(), currentPath.st_uid == getuid(),
                  (descriptorInfo.st_mode & mode_t(0o077)) == 0,
                  descriptorInfo.st_nlink == 1, currentPath.st_nlink == 1,
                  descriptorInfo.st_dev == currentPath.st_dev,
                  descriptorInfo.st_ino == currentPath.st_ino,
                  descriptorInfo.st_size >= 0, descriptorInfo.st_size <= maximumManifestBytes else {
                throw Error.unsafeManifest("\(manifestName) failed its owner-private descriptor check")
            }
        }
        try validate()
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Error.unsafeManifest("read \(manifestName) failed")
            }
            guard output.count <= maximumManifestBytes - count else {
                throw Error.unsafeManifest("\(manifestName) exceeds \(maximumManifestBytes) bytes")
            }
            output.append(buffer, count: count)
        }
        try validate()
        return output
    }
}
