import Foundation

// fca-mcp: an MCP stdio server exposing FloatingChatApp's models.
// Run by an MCP client (e.g. Claude Code). Speaks JSON-RPC 2.0 over stdin/stdout.
MCPServer().run()
