import Foundation
import AgentCore

let kistRawArguments = Array(CommandLine.arguments.dropFirst())

// A host broker request is an exclusive JSON protocol, including malformed CLI invocations.
// Dispatch before version/help, terminal setup, environment mutation, and generic cleanup.
if kistRawArguments.contains("--operator-action") {
    exit(await KistOperatorActionProtocol.run(arguments: kistRawArguments))
}

if kistRawArguments.contains("--inspect-builder-evidence") {
    exit(KistBuilderEvidenceCommand.run(arguments: kistRawArguments))
}

// Deployment metadata must be inspectable without mutating KIST_ACTIVE or touching option parsing,
// project discovery, MCP configuration, provider selection, or model initialization.
if KistBuildInfo.isVersionRequest(kistRawArguments) {
    print(KistBuildInfo.versionText)
    exit(0)
}

if KistBuildInfo.isReleaseNotesRequest(kistRawArguments) {
    print(KistChangelog.modelContext())
    exit(0)
}

// Mythos / kist entry point. One static binary, no external deps.
// Unbuffer stdout so the event sink's writes and the REPL's prompts stay in order
// (we mix print() with raw FileHandle writes for the inline prompt + token stream).
setvbuf(stdout, nil, _IONBF, 0)

// Snapshot stdout TTY-ness BEFORE any screen coordinator can dup2 a capture pipe onto fd 1 —
// color decisions made mid-capture must reflect the real terminal (2026-08-03 white-out fix).
TerminalCapabilities.prime()

let setupRequested = kistRawArguments == ["--setup"]
let opts = KistOptions.parse(setupRequested ? [] : kistRawArguments)

if opts.showHelp {
    print(KistOptions.helpText)
    print("  --setup                 Choose a model, finish setup, then open the terminal session")
    exit(0)
}

guard opts.optionErrors.isEmpty else {
    for error in opts.optionErrors {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    }
    exit(2)
}

if kistRawArguments.isEmpty || setupRequested {
    let startupConfig = KistConfig.load()
    if FirstLaunchSetup.shouldRun(arguments: kistRawArguments, isTTY: KistRunner.stdinIsTTY(),
                                 nested: ProcessInfo.processInfo.environment["KIST_ACTIVE"] == "1",
                                 config: startupConfig) {
        guard await FirstLaunchSetup.run(config: startupConfig) else { exit(2) }
    } else if setupRequested {
        FileHandle.standardError.write(Data("Setup requires an interactive terminal outside an agent child process.\n".utf8))
        exit(2)
    }
}

// Mark this process so any CHILD kist (an agent's run_command → `kist …`) detects nesting and refuses
// self-escalation (computer-use arming / guards-off). parse() above already read the INHERITED value for
// THIS process's nested-detection; setting it now only affects processes we spawn. (Council 2026-07-03.)
setenv("KIST_ACTIVE", "1", 1)

let code = await KistRunner.run(opts)
// Don't orphan background jobs (run_command background:true) — terminate any still-running so they
// can't outlive the session (and so the per-process job cap can't be reset by re-launching).
BackgroundJobStore.shared.killAll()
exit(code)
