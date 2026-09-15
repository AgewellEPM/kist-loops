import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Host-selected installed compiler resources. Captured before sandbox activation; caller/child
/// environment dictionaries cannot add search paths or read authority after attestation.
struct BuilderToolchainEnvironment: Sendable {
    let values: [String: String]
    let readOnlyRoots: [String]

    static func discover(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(), forbiddenReadPaths: [String] = []
    ) throws -> Self {
        var values: [String: String] = [:]
        var bins: [String] = []
        var roots: [String] = []
        func eligible(_ path: String) -> String? {
            guard let canonical = ToolContext.canonicalize(path), trustedDirectory(canonical),
                  !forbiddenReadPaths.contains(where: {
                      let denied = ToolContext.canonicalize($0) ?? $0
                      return canonical == denied || canonical.hasPrefix(denied + "/")
                          || denied.hasPrefix(canonical + "/")
                  }) else { return nil }
            return canonical
        }
        #if os(macOS)
        let developerCandidates = [parent["DEVELOPER_DIR"],
                                   ToolContext.canonicalize("/var/db/xcode_select_link"),
                                   "/Applications/Xcode.app/Contents/Developer",
                                   "/Library/Developer/CommandLineTools"].compactMap { $0 }
        if let developer = developerCandidates.compactMap(eligible).first {
            values["DEVELOPER_DIR"] = developer
            let compilerBin = developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin"
            if trustedDirectory(compilerBin) { bins.append(compilerBin) }
            if trustedDirectory(developer + "/usr/bin") { bins.append(developer + "/usr/bin") }
            let sdkCandidates = [developer + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
                                 developer + "/SDKs/MacOSX.sdk"]
            if let sdk = sdkCandidates.compactMap(eligible).first { values["SDKROOT"] = sdk }
        }
        let javaCandidates = [parent["JAVA_HOME"], "/opt/homebrew/opt/openjdk",
                              "/opt/homebrew/opt/openjdk@21", "/opt/homebrew/opt/openjdk@17"]
            .compactMap { $0 }.flatMap { [$0, $0 + "/libexec/openjdk.jdk/Contents/Home"] }
        if let java = javaCandidates.compactMap(eligible).first(where: {
            trustedExecutable($0 + "/bin/java") && trustedExecutable($0 + "/bin/javac")
        }) {
            values["JAVA_HOME"] = java
            bins.append(java + "/bin")
            roots.append(java)
        }
        // Resolve rustup's selected installed toolchain without launching the rustup shim or giving
        // the child the real HOME. The generated settings file uses a quoted default_toolchain value.
        let settings = URL(fileURLWithPath: home + "/.rustup/settings.toml")
        if let data = try? Data(contentsOf: settings), data.count <= 65_536,
           let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first(where: {
               $0.trimmingCharacters(in: .whitespaces).hasPrefix("default_toolchain = ")
           }), let equals = line.firstIndex(of: "="),
           let selected = try? JSONDecoder().decode(String.self, from: Data(
               line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).utf8)),
           !selected.isEmpty, selected != ".", selected != "..", !selected.contains("/"),
           let rust = eligible(home + "/.rustup/toolchains/" + selected),
           trustedExecutable(rust + "/bin/rustc"), trustedDirectory(rust + "/lib/rustlib") {
            bins.append(rust + "/bin")
            roots.append(rust)
        }
        #endif
        // Explicit host configuration supports already-installed compilers outside system paths.
        // A model's run_command arguments cannot set this value. No download or installation occurs.
        if let raw = parent["KIST_BUILDER_TOOLCHAIN_ROOTS"] {
            guard raw.utf8.count <= 16_384,
                  let configured = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)),
                  configured.count <= 8 else {
                throw BuilderOSProcessSandboxError.invalidRequest("invalid KIST_BUILDER_TOOLCHAIN_ROOTS")
            }
            for path in configured {
                guard (path as NSString).isAbsolutePath, let root = eligible(path),
                      root != "/", root != (ToolContext.canonicalize(home) ?? home),
                      !home.hasPrefix(root + "/") else {
                    throw BuilderOSProcessSandboxError.invalidRequest("unusable configured compiler root")
                }
                let rust = trustedExecutable(root + "/bin/rustc") && trustedDirectory(root + "/lib/rustlib")
                let typescript = trustedExecutable(root + "/bin/tsc")
                    && FileManager.default.isReadableFile(atPath: root + "/lib/typescript.js")
                let java = trustedExecutable(root + "/bin/java") && trustedExecutable(root + "/bin/javac")
                guard rust || typescript || java else {
                    throw BuilderOSProcessSandboxError.invalidRequest("configured root is not an installed Rust, TypeScript, or Java compiler")
                }
                roots.append(root); bins.append(root + "/bin")
                if java { values["JAVA_HOME"] = root }
            }
        }
        let basePath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
        var seen = Set<String>()
        values["PATH"] = (bins + basePath).filter { seen.insert($0).inserted }.joined(separator: ":")
        return Self(values: values, readOnlyRoots: Array(Set(roots)).sorted())
    }

    /// Apple shims consult a per-user xcrun lookup cache even when HOME/TMPDIR are private.
    /// Populate lookup entries with the fixed host tool before entering the worker sandbox. The
    /// worker retains zero write access to that host cache; --no-cache makes this problem worse.
    func prepareSystemLookupCache(environment: [String: String], cwd: String) throws {
        #if os(macOS)
        guard let developer = values["DEVELOPER_DIR"] else { return }
        for tool in ["python3", "make", "clang", "clang++", "swift", "swiftc", "ld", "ar", "ranlib"] {
            guard let resolved = RunCommandTool.resolveExecutable(tool, env: values),
                  resolved.hasPrefix(developer + "/") else { continue }
            let result = ProcessGroupRunner.run(
                launchPath: "/usr/bin/xcrun", launchArgs: ["--find", tool], cwd: cwd,
                env: environment,
                timeoutSeconds: 10, capPerStream: 4_096, graceSeconds: 1)
            guard result.exitCode == 0, !result.timedOut else {
                throw BuilderOSProcessSandboxError.mechanismUnavailable(
                    "could not prepare Xcode compiler lookup for \(tool)")
            }
        }
        #endif
    }

    private static func trustedDirectory(_ path: String) -> Bool {
        trustedNode(path, kind: mode_t(S_IFDIR))
    }

    private static func trustedExecutable(_ path: String) -> Bool {
        guard let resolved = ToolContext.canonicalize(path) else { return false }
        return trustedNode(resolved, kind: mode_t(S_IFREG))
            && FileManager.default.isExecutableFile(atPath: resolved)
    }

    private static func trustedNode(_ path: String, kind: mode_t) -> Bool {
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == kind
            && (info.st_uid == 0 || info.st_uid == getuid()) && info.st_mode & mode_t(0o022) == 0
    }
}
