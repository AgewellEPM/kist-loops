import Foundation

/// A REAL (not stubbed) `PoCReproducer` for source-level findings. Reproduction = re-read the file the
/// finding lives in and re-run the deterministic scanner; the PoC "reproduces" iff the SAME finding id
/// fires again. This is genuinely reproducible ground truth — a deterministic scanner either re-detects
/// the pattern at that file:line or it doesn't — which is exactly what the verify spine needs to promote
/// a source finding to report-ready without any live-target traffic.
///
/// It holds the recon report's findings (id → finding) so it can resolve a PoC back to its file/rule/line;
/// a PoC whose id it doesn't recognize fails closed (not reproduced).
public struct SourceRescanReproducer: PoCReproducer {
    public let root: String
    private let findingsById: [String: SecurityFinding]

    public init(root: String, findings: [SecurityFinding]) {
        self.root = root
        self.findingsById = Dictionary(findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func reproduce(_ poc: ProofOfConcept) async -> ReproResult {
        guard let f = findingsById[poc.findingId] else {
            return ReproResult(reproduced: false, observed: "no known source finding matches PoC \(poc.findingId)")
        }
        // Defense-in-depth (panel review): findings come from our own scanner (paths are repo-relative), but
        // never read THROUGH a `../` escape. Standardize the joined path and require it to stay under root.
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        let full = URL(fileURLWithPath: root).appendingPathComponent(f.file).standardizedFileURL.path
        guard full == base || full.hasPrefix(base + "/") else {
            return ReproResult(reproduced: false, observed: "'\(f.file)' escapes the scan root — refusing to read")
        }
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else {
            return ReproResult(reproduced: false, observed: "could not read \(f.file) to re-scan")
        }
        let rescanned = SecurityAuditor.scanFile(text: text, relativePath: f.file)
        if rescanned.contains(where: { $0.id == f.id }) {
            return ReproResult(reproduced: true,
                               observed: "deterministic re-scan of \(f.file) re-detected rule '\(f.rule)' at line \(f.line)")
        }
        return ReproResult(reproduced: false,
                           observed: "re-scan of \(f.file) no longer fires rule '\(f.rule)' at line \(f.line) (fixed or moved)")
    }
}
