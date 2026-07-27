import Foundation

/// Pure `docker` argv builders. Every run command bakes in the safety floor — no
/// `--privileged`, dropped capabilities, no-new-privileges, resource caps, and the
/// spec's network (default none). Pure ⇒ the safety invariants are unit-testable
/// without a daemon.
public enum DockerCommand {

    /// `docker build -t <tag> [-f <dockerfile>] <context>`
    public static func build(imageTag: String, contextDir: String, dockerfilePath: String? = nil) -> [String] {
        var argv = ["build", "-t", imageTag]
        if let df = dockerfilePath { argv += ["-f", df] }
        argv += [contextDir]
        return argv
    }

    /// `docker run …` with the hardened flags derived from `spec`.
    public static func run(_ spec: ContainerSpec, command: [String] = []) -> [String] {
        var argv = ["run"]
        if spec.ephemeral { argv += ["--rm"] }
        argv += ["--name", spec.name]
        // Safety floor — always present, never overridable by the spec.
        argv += ["--security-opt", "no-new-privileges"]
        argv += ["--cap-drop", "ALL"]
        argv += ["--memory", spec.memory, "--cpus", spec.cpus]
        argv += ["--network", spec.network]
        if spec.readOnlyRootfs { argv += ["--read-only"] }
        if let wd = spec.workdir { argv += ["--workdir", wd] }
        for (k, v) in spec.env.sorted(by: { $0.key < $1.key }) { argv += ["-e", "\(k)=\(v)"] }
        for p in spec.ports { argv += ["-p", "\(p.host):\(p.container)"] }
        for v in spec.volumes { argv += ["-v", "\(v.hostPath):\(v.containerPath)\(v.readOnly ? ":ro" : "")"] }
        argv += [spec.image]
        argv += command
        return argv
    }

    public static func stop(_ name: String) -> [String] { ["stop", name] }
    public static func remove(_ name: String) -> [String] { ["rm", "-f", name] }
    public static func logs(_ name: String) -> [String] { ["logs", name] }

    /// `docker ps` filtered to the managed name prefix — never lists the user's own
    /// containers.
    public static func ps(managedPrefix: String) -> [String] {
        ["ps", "-a", "--filter", "name=\(managedPrefix)", "--format", "{{.Names}}\t{{.Status}}"]
    }
}
