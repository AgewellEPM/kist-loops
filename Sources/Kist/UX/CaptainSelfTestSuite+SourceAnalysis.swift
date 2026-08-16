import Foundation
import AgentCore

// Source-analysis helpers (read/codeOnly/functionBody/assertion checks) for CaptainSelfTestSuite,
// extracted to keep the suite under the size limit. Part of `struct CaptainSelfTestSuite`.
extension CaptainSelfTestSuite {
    func read(_ relativePath: String) -> String? {
        try? String(contentsOfFile: projectRoot + "/" + relativePath, encoding: .utf8)
    }

    func codeOnly(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : "\0"
            let next2 = i + 2 < chars.count ? chars[i + 2] : "\0"
            if c == "/" && next == "/" {
                out.append(" ")
                out.append(" ")
                i += 2
                while i < chars.count && chars[i] != "\n" {
                    out.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/" && next == "*" {
                out.append(" ")
                out.append(" ")
                i += 2
                while i < chars.count {
                    if chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
                        out.append(" ")
                        out.append(" ")
                        i += 2
                        break
                    }
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                continue
            }
            if c == "\"" && next == "\"" && next2 == "\"" {
                out.append(" ")
                out.append(" ")
                out.append(" ")
                i += 3
                while i < chars.count {
                    if chars[i] == "\"" && i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
                        out.append(" ")
                        out.append(" ")
                        out.append(" ")
                        i += 3
                        break
                    }
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                continue
            }
            if c == "\"" {
                out.append(" ")
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" && i + 1 < chars.count {
                        out.append(" ")
                        out.append(" ")
                        i += 2
                        continue
                    }
                    let done = chars[i] == "\""
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                    if done { break }
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    func commentsOnlyRemoved(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : "\0"
            if c == "/" && next == "/" {
                out.append(" ")
                out.append(" ")
                i += 2
                while i < chars.count && chars[i] != "\n" {
                    out.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/" && next == "*" {
                out.append(" ")
                out.append(" ")
                i += 2
                while i < chars.count {
                    if chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
                        out.append(" ")
                        out.append(" ")
                        i += 2
                        break
                    }
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    func hasExecutableAssertion(_ body: String) -> Bool {
        let code = codeOnly(body)
        let assertionSignals = ["XCTAssert", "XCTUnwrap", "XCTFail", "assertOrder("]
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { line in assertionSignals.contains { line.contains($0) } }
        return lines.contains { !isVacuousAssertionLine($0) }
    }

    func isVacuousAssertionLine(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return compact.contains("XCTAssertTrue(true)") ||
            compact.contains("XCTAssert(true)") ||
            compact.contains("XCTAssertEqual(1,1)") ||
            compact.contains("XCTAssertEqual(true,true)")
    }

    func functionBody(named name: String, in source: String) -> String? {
        let code = codeOnly(source)
        guard let range = functionBodyRange(named: name, in: code) else { return nil }
        return String(code[range])
    }

    func functionBodyRange(named name: String, in source: String) -> Range<String.Index>? {
        guard let signature = functionSignature(named: name, in: source) else { return nil }
        guard let open = source[signature.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            let char = source[index]
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    let start = source.index(after: open)
                    return start..<index
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    func rawFunctionBody(named name: String, in source: String) -> String? {
        guard let range = rawFunctionBodyRange(named: name, in: source) else { return nil }
        return String(source[range])
    }

    func rawFunctionBodyRange(named name: String, in source: String) -> Range<String.Index>? {
        guard let signature = functionSignature(named: name, in: source) else { return nil }
        guard let open = source[signature.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        var inLineComment = false
        var inBlockComment = false
        var inString = false
        var inMultilineString = false
        var escaping = false

        while index < source.endIndex {
            let next = source.index(after: index)
            if inLineComment {
                if source[index] == "\n" { inLineComment = false }
                index = next
                continue
            }
            if inBlockComment {
                if source[index...].hasPrefix("*/") {
                    inBlockComment = false
                    index = source.index(index, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
                } else {
                    index = next
                }
                continue
            }
            if inMultilineString {
                if source[index...].hasPrefix("\"\"\"") {
                    inMultilineString = false
                    index = source.index(index, offsetBy: 3, limitedBy: source.endIndex) ?? source.endIndex
                } else {
                    index = next
                }
                continue
            }
            if inString {
                if escaping {
                    escaping = false
                } else if source[index] == "\\" {
                    escaping = true
                } else if source[index] == "\"" {
                    inString = false
                }
                index = next
                continue
            }

            if source[index...].hasPrefix("//") {
                inLineComment = true
                index = source.index(index, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
                continue
            }
            if source[index...].hasPrefix("/*") {
                inBlockComment = true
                index = source.index(index, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
                continue
            }
            if source[index...].hasPrefix("\"\"\"") {
                inMultilineString = true
                index = source.index(index, offsetBy: 3, limitedBy: source.endIndex) ?? source.endIndex
                continue
            }
            if source[index] == "\"" {
                inString = true
                index = next
                continue
            }
            if source[index] == "{" {
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return source.index(after: open)..<index
                }
            }
            index = next
        }
        return nil
    }

    func functionSignature(named name: String, in source: String) -> Range<String.Index>? {
        let needle = "func \(name)"
        var searchRange: Range<String.Index>? = source.startIndex..<source.endIndex
        while let range = source.range(of: needle, range: searchRange) {
            var index = range.upperBound
            while index < source.endIndex && source[index].isWhitespace {
                index = source.index(after: index)
            }
            if index < source.endIndex && source[index] == "(" {
                return range
            }
            searchRange = range.upperBound..<source.endIndex
        }
        return nil
    }

    func boardTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["PLAN:", "ACTION:", "TEST:", "REVIEW:", "RESEARCH:", "DECISION:", "HANDOFF:", "BACKLOG:"] {
            if trimmed.uppercased().hasPrefix(prefix) {
                return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).description
            }
        }
        return trimmed
    }

    static func singleLine(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(0, limit))) + "..."
    }

    static func relative(_ path: String, root: String) -> String {
        let cleanRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == cleanRoot { return "." }
        if path.hasPrefix(cleanRoot + "/") { return String(path.dropFirst(cleanRoot.count + 1)) }
        return path
    }
}
