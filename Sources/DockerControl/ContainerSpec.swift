import Foundation

public struct PortMap: Codable, Sendable, Equatable {
    public let host: Int
    public let container: Int
    public init(host: Int, container: Int) { self.host = host; self.container = container }
}

public struct VolumeMount: Codable, Sendable, Equatable {
    public let hostPath: String
    public let containerPath: String
    public let readOnly: Bool
    public init(hostPath: String, containerPath: String, readOnly: Bool = false) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.readOnly = readOnly
    }
}

/// A hardened container run spec. Defaults are locked down: no network, ephemeral,
/// resource-capped, non-privileged. Callers opt IN to network/ports, never out of
/// the safety floor.
public struct ContainerSpec: Codable, Sendable, Equatable {
    public var image: String
    public var name: String            // must be managed-prefixed (enforced by DockerControl)
    public var env: [String: String]
    public var ports: [PortMap]
    public var volumes: [VolumeMount]
    public var workdir: String?
    public var memory: String          // e.g. "512m"
    public var cpus: String            // e.g. "1.0"
    public var network: String         // default "none"
    public var readOnlyRootfs: Bool
    public var ephemeral: Bool          // --rm

    public init(image: String, name: String, env: [String: String] = [:],
                ports: [PortMap] = [], volumes: [VolumeMount] = [], workdir: String? = nil,
                memory: String = "512m", cpus: String = "1.0", network: String = "none",
                readOnlyRootfs: Bool = false, ephemeral: Bool = true) {
        self.image = image
        self.name = name
        self.env = env
        self.ports = ports
        self.volumes = volumes
        self.workdir = workdir
        self.memory = memory
        self.cpus = cpus
        self.network = network
        self.readOnlyRootfs = readOnlyRootfs
        self.ephemeral = ephemeral
    }
}
