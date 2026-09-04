import Foundation
import AgentCore

extension OrganizationalLearningStore {
    func localModelAcquisitionArtifactAttestationPath(_ manifest: LocalModelAcquisitionManifest) -> String {
        localModelsRoot + "/\(Self.slug(manifest.approvalID + "-download-artifacts")).json"
    }

    func localModelAcquisitionArtifactAttestationPassed(manifest: LocalModelAcquisitionManifest) -> Bool {
        let path = localModelAcquisitionArtifactAttestationPath(manifest)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let attestation = try? JSONDecoder().decode(LocalModelAcquisitionArtifactAttestation.self, from: data) else {
            return false
        }
        guard attestation.accepted
            && attestation.approvalID == manifest.approvalID
            && attestation.policyHash == manifest.policyHash
            && attestation.modelID == manifest.modelID
            && attestation.localDirectory == manifest.localDirectory
            && attestation.revisionSHA == manifest.revisionSHA
            && ForgeSeal.verify(localModelAcquisitionArtifactAttestationCanonical(attestation),
                                seal: attestation.seal ?? "") else {
            return false
        }
        var current = makeLocalModelAcquisitionArtifactAttestation(manifest: manifest)
        current.createdAt = attestation.createdAt
        current.seal = attestation.seal
        return current == attestation
    }

    func makeLocalModelAcquisitionArtifactAttestation(manifest: LocalModelAcquisitionManifest) -> LocalModelAcquisitionArtifactAttestation {
        let fm = FileManager.default
        let rootPath = (projectRoot as NSString).resolvingSymlinksInPath
        let modelsPath = (rootPath as NSString).appendingPathComponent(".kist/models")
        let localPath = (rootPath as NSString).appendingPathComponent(manifest.localDirectory)
        let resolvedModelsPath = (modelsPath as NSString).resolvingSymlinksInPath
        let resolvedLocalPath = (localPath as NSString).resolvingSymlinksInPath
        var blockers: [String] = []
        var warnings: [String] = []
        var files: [LocalModelAcquisitionArtifactFile] = []
        var seen = Set<String>()
        var totalBytes: Int64 = 0

        if Self.isSymbolicLink(rootPath + "/.kist") {
            blockers.append(".kist is a symbolic link")
        }
        if Self.isSymbolicLink(modelsPath) {
            blockers.append(".kist/models is a symbolic link")
        }
        if resolvedLocalPath != resolvedModelsPath && !resolvedLocalPath.hasPrefix(resolvedModelsPath + "/") {
            blockers.append("local directory is outside .kist/models")
        }

        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: localPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            blockers.append("local directory does not exist")
        } else if Self.isSymbolicLink(localPath) {
            blockers.append("local directory is a symbolic link")
        } else if let enumerator = fm.enumerator(atPath: localPath) {
            let expected = Set(manifest.fileNames.filter { !$0.hasPrefix(".cache/") })
            for case let relative as String in enumerator {
                guard Self.isSafeLocalModelArtifactPath(relative) else {
                    blockers.append("unsafe artifact path '\(relative)'")
                    continue
                }
                let fullPath = localPath + "/" + relative
                if Self.isSymbolicLink(fullPath) {
                    blockers.append("symbolic link artifact '\(relative)'")
                    continue
                }
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let type = attrs[.type] as? FileAttributeType else {
                    warnings.append("could not inspect artifact '\(relative)'")
                    continue
                }
                if type == .typeDirectory {
                    continue
                }
                if relative.hasPrefix(".cache/") {
                    continue
                }
                if !expected.contains(relative) {
                    blockers.append("unexpected artifact file '\(relative)'")
                    continue
                }
                guard Self.isAllowedLocalModelArtifactFile(relative) else {
                    blockers.append("unsafe artifact file type '\(relative)'")
                    continue
                }
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if let expectedSize = manifest.fileSizes[relative], size != expectedSize {
                    blockers.append("artifact size mismatch for '\(relative)': expected \(expectedSize), got \(size)")
                    continue
                }
                let hash: String
                do {
                    hash = try MythosCrypto.sha256File(path: fullPath).map { String(format: "%02x", $0) }.joined()
                } catch {
                    blockers.append("could not hash artifact '\(relative)'")
                    continue
                }
                totalBytes += size
                seen.insert(relative)
                files.append(LocalModelAcquisitionArtifactFile(path: relative, bytes: size, sha256: hash))
            }
        }

        let expected = manifest.fileNames.filter { !$0.hasPrefix(".cache/") }
        let missing = expected.filter { !seen.contains($0) }
        if !missing.isEmpty {
            blockers.append("missing manifest file(s): \(Self.joinSample(missing, limit: 8))")
        }
        if files.isEmpty {
            blockers.append("no local model artifacts were found")
        }
        if let expectedBytes = manifest.storageBytes {
            let tolerance = max(Int64(64 * 1_048_576), expectedBytes / 10)
            if totalBytes > expectedBytes + tolerance {
                blockers.append("local artifacts exceed approved storage size")
            }
        } else {
            warnings.append("manifest storage size unavailable; total local bytes recorded without size comparison")
        }

        blockers = Self.unique(blockers)
        warnings = Self.unique(warnings)
        var attestation = LocalModelAcquisitionArtifactAttestation(
            approvalID: manifest.approvalID,
            policyHash: manifest.policyHash,
            modelID: manifest.modelID,
            revisionSHA: manifest.revisionSHA,
            localDirectory: manifest.localDirectory,
            createdAt: now().timeIntervalSince1970,
            accepted: blockers.isEmpty,
            requiredFilesPresent: missing.isEmpty,
            fileCount: files.count,
            totalBytes: totalBytes,
            sampledFiles: files.sorted { $0.path < $1.path }.prefix(50).map { $0 },
            blockers: blockers,
            warnings: warnings,
            seal: nil)
        attestation.seal = ForgeSeal.sign(localModelAcquisitionArtifactAttestationCanonical(attestation))
        return attestation
    }

    func localModelAcquisitionArtifactAttestationCanonical(_ attestation: LocalModelAcquisitionArtifactAttestation) -> String {
        let files = attestation.sampledFiles
            .sorted { $0.path < $1.path }
            .map { "\(ForgeSeal.field($0.path)):\($0.bytes):\(ForgeSeal.field($0.sha256))" }
            .joined(separator: ",")
        return [
            "approval=\(ForgeSeal.field(attestation.approvalID))",
            "policy=\(ForgeSeal.field(attestation.policyHash))",
            "model=\(ForgeSeal.field(attestation.modelID))",
            "revision=\(ForgeSeal.field(attestation.revisionSHA ?? ""))",
            "local=\(ForgeSeal.field(attestation.localDirectory))",
            "createdAt=\(attestation.createdAt)",
            "accepted=\(attestation.accepted ? "1" : "0")",
            "required=\(attestation.requiredFilesPresent ? "1" : "0")",
            "count=\(attestation.fileCount)",
            "bytes=\(attestation.totalBytes)",
            "files=\(files)",
            "blockers=\(attestation.blockers.map(ForgeSeal.field).joined(separator: ","))",
            "warnings=\(attestation.warnings.map(ForgeSeal.field).joined(separator: ","))"
        ].joined(separator: "|")
    }

    func writeLocalModelAcquisitionArtifactAttestation(_ attestation: LocalModelAcquisitionArtifactAttestation,
                                                               manifest: LocalModelAcquisitionManifest) -> String? {
        let path = localModelAcquisitionArtifactAttestationPath(manifest)
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(attestation)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            return Self.projectRelative(path, root: projectRoot)
        } catch {
            return nil
        }
    }

    static func isSafeLocalModelArtifactPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains(".."),
              !value.contains("\0"),
              !value.contains("\\") else { return false }
        return true
    }

    static func isAllowedLocalModelArtifactFile(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        if [".gitattributes", "license", "notice"].contains(name) { return true }
        let ext = (name as NSString).pathExtension
        return ["json", "txt", "md", "safetensors", "gguf", "model", "tiktoken"].contains(ext)
    }

    static func isSymbolicLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    static func joinSample(_ values: [String], limit: Int) -> String {
        let prefix = values.prefix(limit).joined(separator: ", ")
        if values.count > limit {
            return "\(prefix), +\(values.count - limit) more"
        }
        return prefix
    }

    struct LocalModelAcquisitionStageMarker: Codable, Equatable, Sendable {
        var approvalID: String
        var policyHash: String
        var stage: String
        var command: String
        var reportPath: String
        var succeeded: Bool
        var createdAt: Double
        var seal: String?
    }

    func localModelAcquisitionStageMarkerPath(_ stage: LocalModelAcquisitionStage,
                                                      manifest: LocalModelAcquisitionManifest) -> String {
        localModelsRoot + "/\(Self.slug(manifest.approvalID + "-" + stage.rawValue)).passed.json"
    }

    func localModelAcquisitionStagePassed(_ stage: LocalModelAcquisitionStage,
                                                  manifest: LocalModelAcquisitionManifest) -> Bool {
        let path = localModelAcquisitionStageMarkerPath(stage, manifest: manifest)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let marker = try? JSONDecoder().decode(LocalModelAcquisitionStageMarker.self, from: data) else {
            return false
        }
        let reportPath = (projectRoot as NSString).appendingPathComponent(marker.reportPath)
        return marker.succeeded
            && marker.approvalID == manifest.approvalID
            && marker.policyHash == manifest.policyHash
            && marker.stage == stage.rawValue
            && FileManager.default.fileExists(atPath: reportPath)
            && ForgeSeal.verify(localModelAcquisitionStageMarkerCanonical(marker),
                                seal: marker.seal ?? "")
    }

    func writeLocalModelAcquisitionStageMarker(stage: LocalModelAcquisitionStage,
                                                       manifest: LocalModelAcquisitionManifest,
                                                       command: String,
                                                       reportPath: String) -> String? {
        let path = localModelAcquisitionStageMarkerPath(stage, manifest: manifest)
        var marker = LocalModelAcquisitionStageMarker(approvalID: manifest.approvalID,
                                                      policyHash: manifest.policyHash,
                                                      stage: stage.rawValue,
                                                      command: command,
                                                      reportPath: reportPath,
                                                      succeeded: true,
                                                      createdAt: now().timeIntervalSince1970,
                                                      seal: nil)
        marker.seal = ForgeSeal.sign(localModelAcquisitionStageMarkerCanonical(marker))
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(marker)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            return Self.projectRelative(path, root: projectRoot)
        } catch {
            return nil
        }
    }

    func localModelAcquisitionStageMarkerCanonical(_ marker: LocalModelAcquisitionStageMarker) -> String {
        [
            "approval=\(ForgeSeal.field(marker.approvalID))",
            "policy=\(ForgeSeal.field(marker.policyHash))",
            "stage=\(ForgeSeal.field(marker.stage))",
            "command=\(ForgeSeal.field(marker.command))",
            "report=\(ForgeSeal.field(marker.reportPath))",
            "succeeded=\(marker.succeeded ? "1" : "0")",
            "createdAt=\(marker.createdAt)"
        ].joined(separator: "|")
    }

    static func executeLocalModelAcquisitionCommand(_ command: LocalModelAcquisitionRunnableCommand,
                                                    projectRoot: String) -> LocalModelAcquisitionRunOutcome {
        var results: [LocalModelAcquisitionProcessResult] = []
        for invocation in command.invocations {
            let result = runLocalModelAcquisitionInvocation(invocation,
                                                           projectRoot: projectRoot,
                                                           timeoutSeconds: command.timeoutSeconds)
            results.append(result)
            if !result.succeeded { break }
        }
        return LocalModelAcquisitionRunOutcome(results: results)
    }

    static func localModelAcquisitionDependencyBlockers(_ command: LocalModelAcquisitionRunnableCommand) -> [LocalModelAcquisitionDependencyBlocker] {
        var seen = Set<String>()
        var blockers: [LocalModelAcquisitionDependencyBlocker] = []
        for invocation in command.invocations {
            guard seen.insert(invocation.executable).inserted else { continue }
            guard resolveExecutableForLocalModelAcquisition(invocation.executable) == nil else { continue }
            blockers.append(localModelAcquisitionDependencyBlocker(for: invocation.executable))
        }
        return blockers
    }

    static func localModelAcquisitionExecutableTrustBlockers(_ command: LocalModelAcquisitionRunnableCommand,
                                                             projectRoot: String) -> [String] {
        var seen = Set<String>()
        var blockers: [String] = []
        for invocation in command.invocations {
            guard seen.insert(invocation.executable).inserted else { continue }
            guard let path = resolveExecutableForLocalModelAcquisition(invocation.executable) else { continue }
            if !isTrustedLocalModelAcquisitionExecutable(path,
                                                         executable: invocation.executable,
                                                         projectRoot: projectRoot) {
                blockers.append("untrusted acquisition executable '\(invocation.executable)' resolved to '\(path)'")
            }
        }
        return blockers
    }

    static func localModelAcquisitionDependencyBlocker(for executable: String) -> LocalModelAcquisitionDependencyBlocker {
        switch executable {
        case "hf":
            return LocalModelAcquisitionDependencyBlocker(
                executable: executable,
                reason: "Hugging Face CLI is required for manifest dry-run/download stages and is not on PATH",
                setupCommand: "python3 -m pip install --user -U 'huggingface_hub[cli]'",
                verifyCommand: "hf --help")
        case "ollama":
            return LocalModelAcquisitionDependencyBlocker(
                executable: executable,
                reason: "Ollama CLI is required to inspect installed Ollama models and is not on PATH",
                setupCommand: "brew install ollama",
                verifyCommand: "ollama --version")
        case "kist":
            return LocalModelAcquisitionDependencyBlocker(
                executable: executable,
                reason: "Kist must be callable from PATH for recursive inspect/onboard/benchmark stages",
                setupCommand: "export PATH=\"$HOME/bin:$PATH\"",
                verifyCommand: "kist --help")
        default:
            return LocalModelAcquisitionDependencyBlocker(
                executable: executable,
                reason: "required acquisition-stage executable is not on PATH",
                setupCommand: "install \(executable) with your package manager",
                verifyCommand: "\(executable) --help")
        }
    }

    static func runLocalModelAcquisitionInvocation(_ invocation: LocalModelAcquisitionRunnableCommand.Invocation,
                                                           projectRoot: String,
                                                           timeoutSeconds: Int) -> LocalModelAcquisitionProcessResult {
        let display = invocation.display
        guard let executable = resolveExecutableForLocalModelAcquisition(invocation.executable) else {
            return LocalModelAcquisitionProcessResult(label: invocation.label,
                                                      command: display,
                                                      exitCode: 127,
                                                      timedOut: false,
                                                      stdout: "",
                                                      stderr: "executable not found: \(invocation.executable)")
        }
        guard isTrustedLocalModelAcquisitionExecutable(executable,
                                                       executable: invocation.executable,
                                                       projectRoot: projectRoot) else {
            return LocalModelAcquisitionProcessResult(label: invocation.label,
                                                      command: display,
                                                      exitCode: 126,
                                                      timedOut: false,
                                                      stdout: "",
                                                      stderr: "untrusted executable path: \(executable)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.environment = scrubbedLocalModelAcquisitionEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutCapture = LocalModelAcquisitionOutputCapture()
        let stderrCapture = LocalModelAcquisitionOutputCapture()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutCapture.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrCapture.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return LocalModelAcquisitionProcessResult(label: invocation.label,
                                                      command: display,
                                                      exitCode: 126,
                                                      timedOut: false,
                                                      stdout: "",
                                                      stderr: String(describing: error))
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        var timedOut = false
        if finished.wait(timeout: .now() + .seconds(max(1, timeoutSeconds))) == .timedOut {
            timedOut = true
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(2))
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if !process.isRunning {
            stdoutCapture.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderrCapture.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        } else {
            stderrCapture.append(Data("\nprocess still running after timeout termination request".utf8))
        }
        return LocalModelAcquisitionProcessResult(label: invocation.label,
                                                  command: display,
                                                  exitCode: timedOut ? 124 : process.terminationStatus,
                                                  timedOut: timedOut,
                                                  stdout: stdoutCapture.string(),
                                                  stderr: stderrCapture.string())
    }

    final class LocalModelAcquisitionOutputCapture {
        private let lock = NSLock()
        private var data = Data()
        private let cap = 120_000

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard data.count < cap else { return }
            data.append(chunk.prefix(cap - data.count))
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            let wasCapped = data.count >= cap
            lock.unlock()
            let text = String(data: snapshot, encoding: .utf8) ?? ""
            return wasCapped ? text + "\n... output capped ..." : text
        }
    }

    static func resolveExecutableForLocalModelAcquisition(_ executable: String) -> String? {
        let fm = FileManager.default
        if executable == "kist",
           let current = CommandLine.arguments.first,
           fm.isExecutableFile(atPath: current) {
            if current.hasPrefix("/") { return (current as NSString).resolvingSymlinksInPath }
            let cwdPath = (fm.currentDirectoryPath as NSString).appendingPathComponent(current)
            if fm.isExecutableFile(atPath: cwdPath) { return (cwdPath as NSString).resolvingSymlinksInPath }
        }
        if executable.hasPrefix("/") {
            let resolved = (executable as NSString).resolvingSymlinksInPath
            return fm.isExecutableFile(atPath: resolved) ? resolved : nil
        }
        guard !executable.contains("/") else { return nil }
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = (dir as NSString).appendingPathComponent(executable)
            let resolved = (candidate as NSString).resolvingSymlinksInPath
            if fm.isExecutableFile(atPath: resolved) { return resolved }
        }
        return nil
    }

    static func isTrustedLocalModelAcquisitionExecutable(_ path: String,
                                                                 executable: String,
                                                                 projectRoot: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        let root = (projectRoot as NSString).resolvingSymlinksInPath
        if resolved == root || resolved.hasPrefix(root + "/") { return false }
        if resolved.hasPrefix("/tmp/") || resolved.hasPrefix("/private/tmp/") { return false }
        if executable == "kist" {
            let current = CommandLine.arguments.first.map { ($0 as NSString).resolvingSymlinksInPath }
            if current == resolved { return true }
        }
        let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
        let allowedPrefixes = [
            "/opt/homebrew/bin/",
            "/usr/local/bin/",
            "/usr/bin/",
            "/bin/",
            "/usr/sbin/",
            "/sbin/",
            home + "/bin/",
            home + "/.local/bin/"
        ]
        if allowedPrefixes.contains(where: { resolved.hasPrefix($0) }) {
            return true
        }

        // `python3 -m pip install --user`, which is the remediation command emitted above,
        // installs console scripts here on macOS. Keep the exception narrower than a prefix
        // allowlist: only a numeric Python version, the literal `bin` directory, and the exact
        // requested executable are accepted.
        let pythonUserRoot = home + "/Library/Python/"
        guard resolved.hasPrefix(pythonUserRoot) else { return false }
        let components = resolved.dropFirst(pythonUserRoot.count).split(
            separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[1] == "bin",
              components[2] == Substring(executable) else {
            return false
        }
        let versionParts = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(versionParts.count) else { return false }
        return versionParts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
        }
    }

    static func scrubbedLocalModelAcquisitionEnvironment() -> [String: String] {
        let allow = Set(["PATH", "HOME", "USER", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "SHELL"])
        return ProcessInfo.processInfo.environment.filter { allow.contains($0.key) }
    }

}
