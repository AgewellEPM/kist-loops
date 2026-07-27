import Foundation

/// Foundation-only tools for the headless agent loop, all CONFINED to a single
/// root directory (no path escapes outside it). Keeps the agent safe-ish: it
/// can only read/write/run within the project you point it at.
struct AgentTools {
    let root: URL

    init(root: String) {
        // Resolve symlinks so confinement checks compare real paths.
        self.root = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    struct ToolError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Resolve a (possibly relative) path and REJECT anything outside root.
    private func resolve(_ path: String) throws -> URL {
        let raw = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        // Resolve symlinks on the candidate too — a symlink inside root that
        // points outside must NOT pass (Codex CRITICAL).
        let url = raw.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw ToolError(message: "path '\(path)' is outside the allowed project root")
        }
        return url
    }

    // MARK: - Tools

    func readFile(_ path: String) throws -> String {
        let url = try resolve(path)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ToolError(message: "could not read \(path)")
        }
        return text.count > 60_000 ? String(text.prefix(60_000)) + "\n…(truncated)" : text
    }

    func writeFile(_ path: String, content: String) throws -> String {
        let url = try resolve(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "wrote \(content.count) bytes to \(path)"
    }

    func editFile(_ path: String, oldText: String, newText: String) throws -> String {
        let url = try resolve(path)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw ToolError(message: "could not read \(path) to edit")
        }
        guard original.contains(oldText) else { throw ToolError(message: "old_text not found in \(path)") }
        let updated = original.replacingOccurrences(of: oldText, with: newText)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return "edited \(path)"
    }

    func listFiles(_ dir: String) throws -> String {
        let url = try resolve(dir.isEmpty ? "." : dir)
        let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return items.sorted().joined(separator: "\n")
    }

    /// Recursive literal-substring search — pure Foundation, NO shell (so it
    /// never sources ~/.zshenv and stays fully confined to root).
    func grep(_ pattern: String, dir: String?) throws -> String {
        guard !pattern.isEmpty else { throw ToolError(message: "grep pattern is empty") }
        let base = try resolve(dir?.isEmpty == false ? dir! : ".")
        let fm = FileManager.default
        var matches: [String] = []
        let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let url = en?.nextObject() as? URL {
            if matches.count >= 200 { break }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url), data.count < 2_000_000,
                  let text = String(data: data, encoding: .utf8) else { continue }
            let rel = url.path.hasPrefix(root.path)
                ? String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
                : url.path
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains(pattern) {
                matches.append("\(rel):\(i + 1):\(line.prefix(200))")
                if matches.count >= 200 { break }
            }
        }
        return matches.isEmpty ? "(no matches)" : matches.joined(separator: "\n")
    }

    func runCommand(_ command: String, timeout: Int = 120) throws -> String {
        let (out, code) = Shell.run(command, cwd: root.path, timeout: timeout)
        return "exit=\(code)\n" + String(out.prefix(40_000))
    }
}

/// Shell runner (zsh -c). NOTE: shell is REAL — `cd ..`/absolute paths can reach
/// outside `cwd` (the file tools are confined; the shell is not — that's why the
/// agent only gets shell when explicitly enabled). We scrub the environment so a
/// model-driven command can't read inherited secrets (e.g. API keys in env).
enum Shell {
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Minimal environment — no inherited secrets.
    private static var scrubbedEnv: [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = ["PATH": parent["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"]
        for k in ["HOME", "LANG", "LC_ALL", "TMPDIR", "USER"] { if let v = parent[k] { env[k] = v } }
        return env
    }

    static func run(_ command: String, cwd: String, timeout: Int) -> (String, Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-f", "-c", command]   // -f: skip ~/.zshenv etc.
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = scrubbedEnv

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Drain the pipe asynchronously so a child holding it open can't deadlock
        // readDataToEndOfFile past the timeout (Codex HIGH).
        let lock = NSLock()
        var buffer = Data()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if !chunk.isEmpty { lock.lock(); buffer.append(chunk); lock.unlock() }
        }

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch {
            handle.readabilityHandler = nil
            return ("failed to launch: \(error.localizedDescription)", -1)
        }

        if exited.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            kill(proc.processIdentifier, SIGKILL)   // hard-kill; async reader prevents hang
            _ = exited.wait(timeout: .now() + 2)
        }
        // Brief grace for the async reader to flush, then stop. NO blocking
        // availableData read here — a surviving grandchild holding the pipe must
        // never hang the server (Codex HIGH). Orphaned grandchildren are an
        // accepted resource leak, not a hang.
        Thread.sleep(forTimeInterval: 0.05)
        handle.readabilityHandler = nil

        lock.lock(); let out = String(data: buffer, encoding: .utf8) ?? ""; lock.unlock()
        return (out, proc.terminationStatus)
    }
}
