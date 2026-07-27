import Foundation

/// The full sandbox plan for a project: what it is, the Dockerfile to write, the
/// image tag, and the hardened run spec. This is the "auto-configure the Docker we
/// need" piece — from a directory to a ready-to-run, safe container plan.
public struct SandboxPlan: Sendable, Equatable {
    public let kind: ProjectKind
    public let dockerfile: String
    public let imageTag: String
    public let spec: ContainerSpec
}

public struct AutoConfigurator: Sendable {
    public let managedPrefix: String
    private let prober = ProjectProber()
    private let generator = DockerfileGenerator()

    public init(managedPrefix: String = "kist-df-") {
        self.managedPrefix = managedPrefix
    }

    /// Probe `projectDir` and produce a plan. `name` is sanitized + managed-prefixed so
    /// the resulting image/container is always in our namespace. Returns nil for an
    /// unknown project kind (no safe default Dockerfile to invent).
    public func configure(projectDir: URL, name: String) -> SandboxPlan? {
        let kind = prober.probe(projectDir)
        guard let dockerfile = generator.dockerfile(for: kind) else { return nil }
        let scoped = managedPrefix + sanitize(name)
        // Static sites serve on 80; give them a host port. Everything else stays
        // network-isolated by default (opt in to ports explicitly later).
        let spec: ContainerSpec
        if kind == .staticSite {
            spec = ContainerSpec(image: scoped, name: scoped, ports: [PortMap(host: 8080, container: 80)],
                                 network: "bridge")
        } else {
            spec = ContainerSpec(image: scoped, name: scoped)  // safe defaults: no network, ephemeral, capped
        }
        return SandboxPlan(kind: kind, dockerfile: dockerfile, imageTag: scoped, spec: spec)
    }

    private func sanitize(_ s: String) -> String {
        let mapped = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var out = String(mapped)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((out.isEmpty ? "project" : out).prefix(40))
    }
}
