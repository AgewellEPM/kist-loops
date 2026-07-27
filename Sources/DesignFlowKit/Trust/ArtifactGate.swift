import Foundation

/// THE trust spine. A stage's claim of "done" means nothing until its artifact
/// physically exists on disk and is non-empty. This is the single line that
/// separates an honest autonomous loop from boolean-flip theater.
///
/// Fail-closed by construction: any doubt (missing file, empty file, unreadable)
/// is a hard failure that blocks the pipeline. A stage can never advance on a
/// claim alone.
public struct ArtifactGate: Sendable {
    public init() {}

    public enum GateError: Error, CustomStringConvertible, Equatable {
        case missing(stage: AgentKind, path: String)
        case empty(stage: AgentKind, path: String)
        case stale(stage: AgentKind, path: String)

        public var description: String {
            switch self {
            case let .missing(stage, path):
                return "GATE BLOCKED — \(stage.displayName) claimed done but produced no artifact at \(path)"
            case let .empty(stage, path):
                return "GATE BLOCKED — \(stage.displayName) wrote an empty artifact at \(path)"
            case let .stale(stage, path):
                return "GATE BLOCKED — \(stage.displayName) produced no FRESH output at \(path); a stale artifact from a prior run cannot satisfy the gate"
            }
        }
    }

    /// Current modification time of a file, or nil if it doesn't exist. Used to
    /// snapshot state before a stage runs so freshness can be proven afterward.
    public static func modificationTime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Verify the artifact for `stage` exists, is non-empty, and — when
    /// `priorModification` is supplied — was actually (re)written by this run.
    ///
    /// Reused workspaces are the trap: a prior run's artifact already sits on disk,
    /// so mere existence proves nothing. `priorModification` is the artifact's mtime
    /// captured BEFORE the stage produced. If the file wasn't there before (nil),
    /// existence is sufficient. If it WAS there, its mtime must have advanced —
    /// otherwise the stage produced nothing and we fail closed on a stale file.
    ///
    /// Returns the byte count on success; throws `GateError` otherwise.
    @discardableResult
    public func verify(stage: AgentKind, in workspace: URL, priorModification: Date? = nil) throws -> Int {
        let path = stage.artifactPath
        let fileURL = workspace.appendingPathComponent(path)
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw GateError.missing(stage: stage, path: path)
        }
        let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int ?? 0
        guard size > 0 else {
            throw GateError.empty(stage: stage, path: path)
        }
        // Freshness: if the artifact predates this stage's execution and its mtime
        // never advanced, the stage did no real work — block on the stale file.
        if let prior = priorModification {
            guard let current = Self.modificationTime(fileURL), current > prior else {
                throw GateError.stale(stage: stage, path: path)
            }
        }
        return size
    }
}
