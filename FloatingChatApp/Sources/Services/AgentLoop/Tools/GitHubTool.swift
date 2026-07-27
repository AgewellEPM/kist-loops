import Foundation
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "GitHub")

/// Tool to interact with GitHub API: search repos, create issues, manage PRs
final class GitHubTool: AgentTool {
    let name = "github"
    let description = """
        Interact with GitHub: search repositories, create issues, list pull requests, get repository info.
        Requires GitHub token stored in Keychain (key: 'github_token').
        """
    let parameters = [
        ToolParameter(name: "action", type: "string", description: "Action: 'search_repos', 'get_repo', 'list_issues', 'create_issue', 'list_prs', 'get_pr', 'list_my_repos'", required: true),
        ToolParameter(name: "query", type: "string", description: "Search query (for search_repos)", required: false),
        ToolParameter(name: "repo", type: "string", description: "Repository in 'owner/repo' format", required: false),
        ToolParameter(name: "title", type: "string", description: "Issue title (for create_issue)", required: false),
        ToolParameter(name: "body", type: "string", description: "Issue/PR body text", required: false),
        ToolParameter(name: "pr_number", type: "number", description: "Pull request number", required: false),
        ToolParameter(name: "issue_number", type: "number", description: "Issue number", required: false),
        ToolParameter(name: "labels", type: "string", description: "Comma-separated labels", required: false)
    ]

    private var token: String {
        KeychainService.shared.get(key: "github_token") ?? ""
    }

    private let baseURL = "https://api.github.com"

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard !token.isEmpty else {
            return ToolResult(
                success: false,
                output: "",
                error: "GitHub token not configured. Set 'github_token' in Keychain via Settings."
            )
        }

        guard let action = arguments["action"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: action")
        }

        switch action.lowercased() {
        case "search_repos":
            guard let query = arguments["query"] as? String else {
                return ToolResult(success: false, output: "", error: "Missing 'query' parameter for search")
            }
            return await searchRepos(query: query)

        case "get_repo":
            guard let repo = arguments["repo"] as? String else {
                return ToolResult(success: false, output: "", error: "Missing 'repo' parameter")
            }
            return await getRepo(repo: repo)

        case "list_issues":
            guard let repo = arguments["repo"] as? String else {
                return ToolResult(success: false, output: "", error: "Missing 'repo' parameter")
            }
            return await listIssues(repo: repo)

        case "create_issue":
            guard let repo = arguments["repo"] as? String,
                  let title = arguments["title"] as? String else {
                return ToolResult(success: false, output: "", error: "Missing 'repo' or 'title' parameter")
            }
            let body = arguments["body"] as? String
            let labels = (arguments["labels"] as? String)?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            return await createIssue(repo: repo, title: title, body: body, labels: labels)

        case "list_prs":
            guard let repo = arguments["repo"] as? String else {
                return ToolResult(success: false, output: "", error: "Missing 'repo' parameter")
            }
            return await listPRs(repo: repo)

        case "get_pr":
            guard let repo = arguments["repo"] as? String,
                  let prNumber = arguments["pr_number"] as? Int else {
                return ToolResult(success: false, output: "", error: "Missing 'repo' or 'pr_number' parameter")
            }
            return await getPR(repo: repo, number: prNumber)

        case "list_my_repos":
            return await listMyRepos()

        default:
            return ToolResult(success: false, output: "", error: "Unknown action: \(action)")
        }
    }

    // MARK: - API Methods

    private func searchRepos(query: String) async -> ToolResult {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "\(baseURL)/search/repositories?q=\(encodedQuery)&per_page=10"

        guard let result = await makeRequest(url: url) else {
            return ToolResult(success: false, output: "", error: "Failed to search repositories")
        }

        guard let items = result["items"] as? [[String: Any]] else {
            return ToolResult(success: true, output: "No repositories found for: \(query)", metadata: nil)
        }

        var output = "Found \(items.count) repositories:\n\n"

        for item in items {
            let name = item["full_name"] as? String ?? "Unknown"
            let desc = item["description"] as? String ?? "No description"
            let stars = item["stargazers_count"] as? Int ?? 0
            let language = item["language"] as? String ?? "Unknown"

            output += "⭐ \(stars) | \(name)\n"
            output += "   \(language) | \(desc.prefix(80))\n\n"
        }

        return ToolResult(success: true, output: output, metadata: ["count": String(items.count)])
    }

    private func getRepo(repo: String) async -> ToolResult {
        let url = "\(baseURL)/repos/\(repo)"

        guard let result = await makeRequest(url: url) else {
            return ToolResult(success: false, output: "", error: "Failed to get repository: \(repo)")
        }

        let name = result["full_name"] as? String ?? repo
        let desc = result["description"] as? String ?? "No description"
        let stars = result["stargazers_count"] as? Int ?? 0
        let forks = result["forks_count"] as? Int ?? 0
        let language = result["language"] as? String ?? "Unknown"
        let openIssues = result["open_issues_count"] as? Int ?? 0
        let defaultBranch = result["default_branch"] as? String ?? "main"
        let htmlURL = result["html_url"] as? String ?? ""

        let output = """
        Repository: \(name)
        Description: \(desc)
        Language: \(language)
        Stars: \(stars) | Forks: \(forks)
        Open Issues: \(openIssues)
        Default Branch: \(defaultBranch)
        URL: \(htmlURL)
        """

        return ToolResult(success: true, output: output, metadata: ["repo": name])
    }

    private func listIssues(repo: String) async -> ToolResult {
        let url = "\(baseURL)/repos/\(repo)/issues?state=open&per_page=10"

        guard let items = await makeRequestArray(url: url) else {
            return ToolResult(success: false, output: "", error: "Failed to list issues for: \(repo)")
        }

        if items.isEmpty {
            return ToolResult(success: true, output: "No open issues in \(repo)", metadata: nil)
        }

        var output = "Open issues in \(repo):\n\n"

        for item in items {
            // Skip pull requests (they appear in issues endpoint)
            if item["pull_request"] != nil { continue }

            let number = item["number"] as? Int ?? 0
            let title = item["title"] as? String ?? "Untitled"
            let user = (item["user"] as? [String: Any])?["login"] as? String ?? "Unknown"
            let labels = (item["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""

            output += "#\(number): \(title)\n"
            output += "   by \(user)"
            if !labels.isEmpty {
                output += " | Labels: \(labels)"
            }
            output += "\n\n"
        }

        return ToolResult(success: true, output: output, metadata: ["repo": repo])
    }

    private func createIssue(repo: String, title: String, body: String?, labels: [String]?) async -> ToolResult {
        let url = "\(baseURL)/repos/\(repo)/issues"

        var payload: [String: Any] = ["title": title]
        if let body = body {
            payload["body"] = body
        }
        if let labels = labels, !labels.isEmpty {
            payload["labels"] = labels
        }

        guard let result = await makeRequest(url: url, method: "POST", body: payload) else {
            return ToolResult(success: false, output: "", error: "Failed to create issue")
        }

        let number = result["number"] as? Int ?? 0
        let htmlURL = result["html_url"] as? String ?? ""

        return ToolResult(
            success: true,
            output: "Created issue #\(number): \(title)\nURL: \(htmlURL)",
            metadata: ["issue_number": String(number), "url": htmlURL]
        )
    }

    private func listPRs(repo: String) async -> ToolResult {
        let url = "\(baseURL)/repos/\(repo)/pulls?state=open&per_page=10"

        guard let items = await makeRequestArray(url: url) else {
            return ToolResult(success: false, output: "", error: "Failed to list PRs for: \(repo)")
        }

        if items.isEmpty {
            return ToolResult(success: true, output: "No open pull requests in \(repo)", metadata: nil)
        }

        var output = "Open PRs in \(repo):\n\n"

        for item in items {
            let number = item["number"] as? Int ?? 0
            let title = item["title"] as? String ?? "Untitled"
            let user = (item["user"] as? [String: Any])?["login"] as? String ?? "Unknown"
            let head = (item["head"] as? [String: Any])?["ref"] as? String ?? ""
            let base = (item["base"] as? [String: Any])?["ref"] as? String ?? ""

            output += "#\(number): \(title)\n"
            output += "   by \(user) | \(head) → \(base)\n\n"
        }

        return ToolResult(success: true, output: output, metadata: ["repo": repo])
    }

    private func getPR(repo: String, number: Int) async -> ToolResult {
        let url = "\(baseURL)/repos/\(repo)/pulls/\(number)"

        guard let result = await makeRequest(url: url) else {
            return ToolResult(success: false, output: "", error: "Failed to get PR #\(number)")
        }

        let title = result["title"] as? String ?? "Untitled"
        let body = result["body"] as? String ?? ""
        let state = result["state"] as? String ?? ""
        let user = (result["user"] as? [String: Any])?["login"] as? String ?? "Unknown"
        let head = (result["head"] as? [String: Any])?["ref"] as? String ?? ""
        let base = (result["base"] as? [String: Any])?["ref"] as? String ?? ""
        let additions = result["additions"] as? Int ?? 0
        let deletions = result["deletions"] as? Int ?? 0
        let changedFiles = result["changed_files"] as? Int ?? 0
        let htmlURL = result["html_url"] as? String ?? ""

        let output = """
        PR #\(number): \(title)
        Author: \(user)
        State: \(state)
        Branch: \(head) → \(base)
        Changes: +\(additions) -\(deletions) in \(changedFiles) files
        URL: \(htmlURL)

        Description:
        \(body.prefix(500))\(body.count > 500 ? "..." : "")
        """

        return ToolResult(success: true, output: output, metadata: ["pr_number": String(number)])
    }

    private func listMyRepos() async -> ToolResult {
        let url = "\(baseURL)/user/repos?per_page=20&sort=updated"

        guard let items = await makeRequestArray(url: url) else {
            return ToolResult(success: false, output: "", error: "Failed to list your repositories")
        }

        if items.isEmpty {
            return ToolResult(success: true, output: "No repositories found", metadata: nil)
        }

        var output = "Your repositories:\n\n"

        for item in items {
            let name = item["full_name"] as? String ?? "Unknown"
            let desc = item["description"] as? String ?? "No description"
            let isPrivate = item["private"] as? Bool ?? false
            let language = item["language"] as? String ?? ""

            let visibility = isPrivate ? "🔒" : "🌐"
            output += "\(visibility) \(name)"
            if !language.isEmpty {
                output += " (\(language))"
            }
            output += "\n   \(desc.prefix(60))\n\n"
        }

        return ToolResult(success: true, output: output, metadata: ["count": String(items.count)])
    }

    // MARK: - HTTP Helpers

    private func makeRequest(url: String, method: String = "GET", body: [String: Any]? = nil) async -> [String: Any]? {
        guard let requestURL = URL(string: url) else { return nil }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            if httpResponse.statusCode >= 400 {
                logger.error("GitHub API error: \(httpResponse.statusCode)")
                return nil
            }

            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            logger.error("GitHub request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func makeRequestArray(url: String) async -> [[String: Any]]? {
        guard let requestURL = URL(string: url) else { return nil }

        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            if httpResponse.statusCode >= 400 {
                logger.error("GitHub API error: \(httpResponse.statusCode)")
                return nil
            }

            return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            logger.error("GitHub request failed: \(error.localizedDescription)")
            return nil
        }
    }
}
