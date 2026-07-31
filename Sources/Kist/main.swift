import Foundation
import AgentCore

let kistRawArguments = Array(CommandLine.arguments.dropFirst())

// Deployment metadata must be inspectable without mutating KIST_ACTIVE or touching option parsing,
// project discovery, MCP configuration, provider selection, or model initialization.
if KistBuildInfo.isVersionRequest(kistRawArguments) {
    print(KistBuildInfo.versionText)
    exit(0)
}

// Mythos / kist entry point. One static binary, no external deps.
// Unbuffer stdout so the event sink's writes and the REPL's prompts stay in order
// (we mix print() with raw FileHandle writes for the inline prompt + token stream).
setvbuf(stdout, nil, _IONBF, 0)

let opts = KistOptions.parse(kistRawArguments)

// Mark this process so any CHILD kist (an agent's run_command → `kist …`) detects nesting and refuses
// self-escalation (computer-use arming / guards-off). parse() above already read the INHERITED value for
// THIS process's nested-detection; setting it now only affects processes we spawn. (Council 2026-07-03.)
setenv("KIST_ACTIVE", "1", 1)

if opts.showHelp {
    print(KistOptions.helpText)
    exit(0)
}

let code = await KistRunner.run(opts)
// Don't orphan background jobs (run_command background:true) — terminate any still-running so they
// can't outlive the session (and so the per-process job cap can't be reset by re-launching).
BackgroundJobStore.shared.killAll()
exit(code)
