import Foundation
import AgentCore

// Working-tree capture for co-review: the bounded uncommitted diff (tracked + untracked),
// symlink-safe bounded file reads, synthetic new-file blocks, and porcelain status parsing.
// Extracted verbatim from KistREPL.swift.
extension KistREPL {
    /// The uncommitted working-tree diff vs HEAD (staged + unstaged) PLUS untracked NEW files. `git diff
    /// HEAD` omits untracked files entirely, so a turn that CREATES a file (very common — "write a new
    /// module") would otherwise produce an empty diff and the `/copilot` co-reviewer would review nothing.
    /// Untracked files are appended as synthetic `new file` blocks. Every path receives its own bounded
    /// representation: a large pre-existing untracked file must never consume a global budget and make a
    /// later file invisible to the pre/post turn delta. Capture failures are explicit incomplete markers,
    /// never an empty string that a caller could mistake for a clean tree.
    static func workingTreeDiff(projectRoot: String) -> String {
        func git(_ args: [String], maxBytes: Int = 1_000_000) -> (text: String, truncated: Bool, digest: String)? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", projectRoot] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            // Drain incrementally before waiting so a large diff cannot deadlock or be materialized in
            // memory. Hash discarded bytes as well: if a same-sized change occurs beyond the captured
            // prefix, the turn delta still changes to an explicit incomplete-review marker.
            var captured = Data()
            var totalBytes = 0
            var digest: UInt64 = 14_695_981_039_346_656_037
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 64 * 1_024)
                if chunk.isEmpty { break }
                totalBytes += chunk.count
                for byte in chunk {
                    digest ^= UInt64(byte)
                    digest &*= 1_099_511_628_211
                }
                let remaining = max(0, maxBytes - captured.count)
                if remaining > 0 { captured.append(contentsOf: chunk.prefix(remaining)) }
            }
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let text = String(data: captured, encoding: .utf8) else { return nil }
            return (text, totalBytes > maxBytes, String(digest, radix: 16))
        }
        let tracked = git(["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--"])
        var out = tracked?.text
            ?? "[review input incomplete: tracked git diff capture failed]\n"
        if let tracked, tracked.truncated {
            out += "\n[review input incomplete: tracked diff exceeded 1000000 bytes; digest=\(tracked.digest)]\n"
        }
        // NUL delimiters preserve literal newlines and other unusual bytes in repository paths. The path
        // is subsequently opened through ConfinedRoot, not as an absolute filesystem string.
        let untrackedCapture = git(["ls-files", "--others", "--exclude-standard", "-z", "--"])
        if untrackedCapture == nil {
            out += "\n[review input incomplete: untracked git path capture failed]\n"
        }
        if let untrackedCapture, untrackedCapture.truncated {
            out += "\n[review input incomplete: untracked path list exceeded 1000000 bytes; digest=\(untrackedCapture.digest)]\n"
        }
        let untracked = untrackedCapture?.truncated == false
            ? (untrackedCapture?.text ?? "").split(separator: "\0").map(String.init)
            : []
        let maxUntrackedFiles = 256
        guard untracked.count <= maxUntrackedFiles else {
            let digest = untrackedCapture?.digest ?? "unavailable"
            out += "\n[review input incomplete: untracked file count \(untracked.count) exceeded \(maxUntrackedFiles); digest=\(digest)]\n"
            return out
        }
        let confined: ConfinedRoot
        do {
            confined = try ConfinedRoot(root: projectRoot)
        } catch {
            out += "\n[review input incomplete: project root could not be opened safely]\n"
            return out
        }
        let perFileBudget = 20_000
        let maxAggregateBytes = 1_500_000
        var aggregateBytes = out.utf8.count
        for rel in untracked where !rel.isEmpty {
            // Read only enough bytes to represent this file's review budget. Loading an entire huge
            // untracked artifact here used to make an otherwise small build turn hang or exhaust memory.
            // The confined prefix read uses O_NOFOLLOW for every component, so an untracked symlink can
            // never make automatic review ingest bytes from outside the repository. Four bytes per Unicode
            // scalar covers the maximum UTF-8 width; one extra scalar proves worst-case truncation.
            guard let content = Self.boundedUTF8FileContents(
                confinedRoot: confined, path: rel, maxBytes: (perFileBudget + 1) * 4
            ) else {
                // Preserve the existence of an unreviewable artifact in the turn delta. Silently
                // dropping it would let a reviewer report clean despite never seeing the file.
                let block = "\ndiff --git a/\(rel) b/\(rel)\n[review input incomplete: symlink, binary, or unreadable file omitted]\n"
                guard aggregateBytes + block.utf8.count <= maxAggregateBytes else {
                    out += "\n[review input incomplete: aggregate repository review capture exceeded \(maxAggregateBytes) bytes]\n"
                    break
                }
                out += block
                aggregateBytes += block.utf8.count
                continue
            }
            let block = Self.syntheticNewFileDiff(path: rel, content: content, maxChars: perFileBudget)
            guard aggregateBytes + block.utf8.count <= maxAggregateBytes else {
                out += "\n[review input incomplete: aggregate repository review capture exceeded \(maxAggregateBytes) bytes]\n"
                break
            }
            out += block
            aggregateBytes += block.utf8.count
        }
        return out
    }

    /// Read a bounded UTF-8 prefix without ever materializing the whole file. Invalid/binary prefixes are
    /// not reviewable text. A byte cap can bisect one UTF-8 scalar, so retry after dropping at most three
    /// trailing bytes before rejecting the file.
    static func boundedUTF8FileContents(path: String, maxBytes: Int) -> String? {
        guard maxBytes > 0,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let payload: Data?
        do { payload = try handle.read(upToCount: maxBytes) }
        catch { return nil }
        guard var data = payload else { return nil }
        if data.contains(0) { return nil }
        for _ in 0..<4 {
            if let text = String(data: data, encoding: .utf8) { return text }
            guard !data.isEmpty else { break }
            data.removeLast()
        }
        return nil
    }

    /// Symlink-safe variant used for repository review capture. Every component is opened relative to
    /// the trusted root descriptor with O_NOFOLLOW, and only a bounded prefix enters model context.
    static func boundedUTF8FileContents(confinedRoot: ConfinedRoot, path: String,
                                        maxBytes: Int) -> String? {
        guard maxBytes > 0,
              let prefix = try? confinedRoot.readDataPrefix(path, maxBytes: maxBytes) else { return nil }
        var data = prefix.data
        if data.contains(0) { return nil }
        for _ in 0..<4 {
            if let text = String(data: data, encoding: .utf8) { return text }
            guard !data.isEmpty else { break }
            data.removeLast()
        }
        return nil
    }

    /// Format an untracked file as a synthetic unified-diff `new file` block so the co-reviewer reads a
    /// freshly-created file like any other change. Pure + testable; content clipped to `maxChars`.
    static func syntheticNewFileDiff(path: String, content: String, maxChars: Int) -> String {
        let clipped = content.count > maxChars
            ? String(content.prefix(maxChars)) + "\n… [new file truncated at \(maxChars) chars]"
            : content
        let body = clipped.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "+" + $0 }.joined(separator: "\n")
        return "\ndiff --git a/\(path) b/\(path)\nnew file\n--- /dev/null\n+++ b/\(path)\n\(body)\n"
    }

    /// The uncommitted changed file paths vs HEAD (name-only) — for the great-loop verifier's anti-gaming
    /// check (which files did this cycle touch). Empty when git is absent or nothing changed.
    static func workingTreeChangedFiles(projectRoot: String) -> [String] {
        // `git status --porcelain` — NOT `git diff --name-only HEAD` — because a from-scratch task's files
        // are UNTRACKED (the loop never `git add`s), and `git diff HEAD` misses untracked files entirely.
        // That made the continuity note empty → the loop re-created work already done → DUPLICATE packages
        // (root + subdir). Porcelain covers modified + added + untracked in one shot; `-uall` lists the
        // individual files inside new dirs, not just the dir.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", projectRoot, "status", "--porcelain", "--untracked-files=all"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return parseGitStatusPorcelain(String(decoding: data, as: UTF8.self))
    }

    /// Parse `git status --porcelain` output to a list of paths. Each line is `XY <path>` (2 status columns
    /// + a space); a rename is `R  old -> new` (we take the NEW path). Git-quoted paths (spaces/unicode) are
    /// unquoted. Pure, so the parsing is unit-tested without a git repo.
    static func parseGitStatusPorcelain(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line -> String? in
            let s = String(line)
            guard s.count > 3 else { return nil }
            var path = String(s.dropFirst(3))                 // drop the 2 status columns + the space
            if let r = path.range(of: " -> ") { path = String(path[r.upperBound...]) }   // rename → new name
            path = path.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                path = String(path.dropFirst().dropLast())     // git quotes paths with odd chars
            }
            return path.isEmpty ? nil : path
        }
    }

    /// Dragging a screenshot thumbnail into Terminal.app fires many drop events → the SAME file path gets
    /// typed dozens/hundreds of times (Luke: "1 image repeated 1000x"). Bracketed-paste de-dup misses it
    /// because a drag arrives as raw keystrokes, not a paste. So: at submit time, any path-like token that
    /// appears 3+ times is a flood — keep the FIRST occurrence, drop the rest, leave the real message intact.
    static func collapseFloodedPaths(_ input: String) -> String {
        let toks = input.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard toks.count > 3 else { return input }
        var counts: [String: Int] = [:]
        for t in toks where t.contains("/") && t.count > 12 { counts[t, default: 0] += 1 }
        let flooded = Set(counts.filter { $0.value >= 3 }.keys)
        guard !flooded.isEmpty else { return input }
        var seen = Set<String>()
        var out: [String] = []
        for t in toks {
            if flooded.contains(t) {
                if seen.contains(t) { continue }
                seen.insert(t)
            }
            out.append(t)
        }
        return out.joined(separator: " ")
    }
}
