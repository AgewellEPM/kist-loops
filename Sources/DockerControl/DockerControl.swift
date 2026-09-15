import Foundation

/// Executes Docker operations — but ONLY on containers/images this system manages.
/// The core safety invariant: every name-targeting operation REFUSES a name that
/// isn't `managedPrefix`-scoped, so the loop can never stop/remove/inspect a user's
/// own container. Uses an injectable runner so the whole thing is testable without a
/// daemon.
public struct DockerControl: Sendable {
    public let managedPrefix: String
    private let runner: @Sendable ([String]) -> (Int32, String)

    public init(managedPrefix: String = "kist-df-",
                runner: (@Sendable ([String]) -> (Int32, String))? = nil) {
        self.managedPrefix = managedPrefix
        self.runner = runner ?? { DockerEnvironment.processRunner($0) }
    }

    public enum ControlError: Error, CustomStringConvertible, Equatable {
        case unavailable(String)
        case refusedUnmanaged(name: String, prefix: String)
        case invalidImage
        case commandFailed(argv: String, code: Int32, output: String)
        public var description: String {
            switch self {
            case let .unavailable(r): return "docker unavailable: \(r)"
            case let .refusedUnmanaged(name, prefix):
                return "refusing to operate on “\(name)” — not managed (must start with \(prefix))"
            case .invalidImage:
                return "container image must be a nonempty image reference, not an option"
            case let .commandFailed(argv, code, out):
                return "docker \(argv) failed (\(code)): \(out.prefix(300))"
            }
        }
    }

    public struct RunOutcome: Sendable, Equatable {
        public let exitCode: Int32
        public let output: String
        public var ok: Bool { exitCode == 0 }
    }

    /// Managed name = has our prefix. Enforced before any name-targeting op.
    public func isManaged(_ name: String) -> Bool { name.hasPrefix(managedPrefix) }

    private func requireAvailable() throws {
        if case let .unavailable(r) = DockerEnvironment.detect(runner: runner) {
            throw ControlError.unavailable(r)
        }
    }

    private func requireManaged(_ name: String) throws {
        guard isManaged(name) else { throw ControlError.refusedUnmanaged(name: name, prefix: managedPrefix) }
    }

    @discardableResult
    public func buildImage(tag: String, contextDir: String, dockerfilePath: String? = nil) throws -> RunOutcome {
        try requireAvailable()
        try requireManaged(tag)   // image tags are managed-scoped too
        return try exec(DockerCommand.build(imageTag: tag, contextDir: contextDir, dockerfilePath: dockerfilePath))
    }

    @discardableResult
    public func run(_ spec: ContainerSpec, command: [String] = []) throws -> RunOutcome {
        guard !spec.image.isEmpty, !spec.image.hasPrefix("-"),
              !spec.image.contains(where: { $0.isWhitespace || $0.isNewline }),
              !spec.image.utf8.contains(0) else { throw ControlError.invalidImage }
        try requireAvailable()
        try requireManaged(spec.name)
        return try exec(DockerCommand.run(spec, command: command))
    }

    @discardableResult
    public func stop(_ name: String) throws -> RunOutcome {
        try requireAvailable(); try requireManaged(name)
        return try exec(DockerCommand.stop(name))
    }

    @discardableResult
    public func remove(_ name: String) throws -> RunOutcome {
        try requireAvailable(); try requireManaged(name)
        return try exec(DockerCommand.remove(name))
    }

    public func logs(_ name: String) throws -> RunOutcome {
        try requireAvailable(); try requireManaged(name)
        return try exec(DockerCommand.logs(name))
    }

    /// List only our managed containers.
    public func listManaged() throws -> RunOutcome {
        try requireAvailable()
        return try exec(DockerCommand.ps(managedPrefix: managedPrefix))
    }

    private func exec(_ argv: [String]) throws -> RunOutcome {
        let (code, out) = runner(argv)
        guard code == 0 else {
            throw ControlError.commandFailed(argv: argv.joined(separator: " "), code: code, output: out)
        }
        return RunOutcome(exitCode: code, output: out)
    }
}
