import Foundation

public extension ResearchRunTool {
    /// Extract explicit public-web candidates from a research goal. This performs only deterministic
    /// syntax canonicalization; `research_run(fetch)` remains the authority for DNS/IP SSRF checks.
    static func canonicalGoalURLs(in goal: String, limit: Int = 8) -> [String] {
        guard limit > 0,
              let expression = try? NSRegularExpression(
                  pattern: #"https?://[^\s<>\"']+"#,
                  options: [.caseInsensitive]
              ) else { return [] }

        let range = NSRange(goal.startIndex..<goal.endIndex, in: goal)
        var seen = Set<String>()
        var urls: [String] = []
        for match in expression.matches(in: goal, range: range) {
            guard let swiftRange = Range(match.range, in: goal) else { continue }
            var candidate = String(goal[swiftRange])
            while let last = candidate.last, ".,;:!?)]}".contains(last) {
                candidate.removeLast()
            }
            guard var components = URLComponents(string: candidate),
                  let rawScheme = components.scheme?.lowercased(),
                  rawScheme == "http" || rawScheme == "https",
                  let rawHost = components.host, !rawHost.isEmpty,
                  components.user == nil, components.password == nil else { continue }

            components.scheme = rawScheme
            components.host = rawHost.lowercased()
            components.fragment = nil
            if (rawScheme == "http" && components.port == 80)
                || (rawScheme == "https" && components.port == 443) {
                components.port = nil
            }
            guard let canonical = components.string, seen.insert(canonical).inserted else { continue }
            urls.append(canonical)
            if urls.count == limit { break }
        }
        return urls
    }
}
