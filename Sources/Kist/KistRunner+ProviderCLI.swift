import Foundation
import AgentCore

/// Small CLI reporting/auth verbs, extracted from KistRunner (RED-zone modular split, behavior-preserving):
/// the one-time remote-MCP OAuth authorize, the provider listing, and the resumable-runs listing.
extension KistRunner {

    /// `kist mcp auth <server> <metadata-url> [client-id] [scope]` — one-time interactive OAuth authorize
    /// for a remote MCP server. Discovers the auth-server metadata, opens the browser, catches the loopback
    /// redirect, exchanges the code, and persists the token where the client manager reads it.
    static func runMCPAuth(_ args: [String]) async -> Int32 {
        guard args.count >= 2, let metaURL = URL(string: args[1]) else {
            print("usage: kist mcp auth <server-name> <metadata-url> [client-id] [scope]")
            print("  <metadata-url> is the OAuth authorization-server metadata (RFC 8414), e.g. https://host/.well-known/oauth-authorization-server")
            return 2
        }
        let server = args[0]
        let clientID = args.count >= 3 ? args[2] : nil
        let scope = args.count >= 4 ? args[3] : nil
        do {
            print("· discovering OAuth metadata for '\(server)' …")
            let metadata = try await MCPOAuthFlow.discoverMetadata(metaURL)
            print("· opening your browser to authorize (complete the login there) …")
            try await MCPOAuthFlow.authorize(serverName: server, metadata: metadata, clientID: clientID,
                                             scope: scope, store: OAuthTokenStore())
            print("\u{001B}[32m✓ authorized '\(server)' — token stored. It will be used (and refreshed) automatically.\u{001B}[0m")
            return 0
        } catch {
            print("\u{001B}[31m✗ authorize failed: \(error.localizedDescription)\u{001B}[0m")
            return 1
        }
    }

    static func listProviders(_ registry: ProviderRegistry) -> Int32 {
        print("Providers (✓ = key configured / no key needed):")
        for p in registry.providers {
            let mark = registry.hasKey(for: p) ? "\u{001B}[32m✓\u{001B}[0m" : "\u{001B}[31m✗\u{001B}[0m"
            let kind = p.requiresAPIKey ? "key: \(p.keyAccount)" : "local"
            print("  \(mark) \(p.id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(p.name)  (\(kind))")
        }
        return 0
    }

    static func listRuns(_ store: LoopCheckpointStore) -> Int32 {
        let runs = store.resumable()
        if runs.isEmpty { print("no resumable runs."); return 0 }
        print("Resumable runs (newest first):")
        for c in runs {
            print("  \(c.id)  [\(c.status.rawValue)]  iter \(c.iteration)  \(c.providerId)  \(c.title)")
        }
        return 0
    }
}
