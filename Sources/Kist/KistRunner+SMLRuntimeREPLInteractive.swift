import Foundation
import AgentCore

/// `kist --sml-runtime-repl <source.json>` with NO `--sml-line`: the interactive loop — the
/// custom REPL a generated runtime always described, finally living. Bounded UTF-8 line input over
/// the same generated per-workflow line compiler the one-shot path proves (no TUI, by design: this
/// surface must work over ssh, in scripts, and inside the generated standalone binary).
///
/// In durable mode the loop is a complete one-terminal harness: the same production drivers and
/// approval-gated pump as serve mode run behind the prompt, so `start` parks at the gate, the
/// prompt shows `[1 pending]`, `approve TASK-X {"task_revision":N}` releases it, and the pump
/// dispatches before the next prompt renders. Ephemeral mode stays a safe sandbox — no drivers,
/// external steps park honestly.
extension KistRunner {
    static func runSMLRuntimeREPLInteractive(_ opts: KistOptions) async -> Int32 {
        do {
            let mode: SMLRuntimeHostMode = opts.smlRuntimeDurable ? .durable : .ephemeralExport
            return try await withSMLRuntimeHostLaunch(
                sourcePath: opts.smlRuntimeREPL,
                projectRoot: opts.project,
                mode: mode,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            ) { host in
                try await interactiveREPLLoop(host, opts: opts)
            }
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    private static func interactiveREPLLoop(
        _ host: SMLRuntimeHostLaunch,
        opts: KistOptions
    ) async throws -> Int32 {
        let availableWorkflowIDs = host.runtimePackage.workflowIDs
        let workflowID = try selectSMLRuntimeREPLWorkflowID(
            opts.smlRuntimeWorkflowID,
            availableWorkflowIDs: availableWorkflowIDs
        )
        let session = try host.launch.app.replSession(workflowID: workflowID)

        // Durable interactive mode gets the full dispatch stack behind the prompt.
        if host.durableEnvironment != nil {
            let actor = opts.smlRuntimeActor ?? "sml-runtime-exporter"
            return try await withSMLRuntimeCapabilityStack(
                host: host,
                projectRoot: opts.project,
                actor: actor,
                enableComputerUse: opts.enableComputerUse
            ) { stack in
                try await runInteractiveREPLSession(
                    host: host,
                    workflowID: workflowID,
                    session: session,
                    pump: stack.pump,
                    projectRoot: opts.project
                )
            }
        }

        return try await runInteractiveREPLSession(
            host: host,
            workflowID: workflowID,
            session: session,
            pump: nil,
            projectRoot: opts.project
        )
    }

    private static func runInteractiveREPLSession(
        host: SMLRuntimeHostLaunch,
        workflowID: String,
        session: SMLWorkflowREPLSession,
        pump: SMLRuntimeCapabilityPump?,
        projectRoot: String
    ) async throws -> Int32 {
        print("sml workflow repl · \(workflowID) · type 'help' for verbs, 'exit' to leave")
        if host.durableEnvironment == nil {
            print("(ephemeral sandbox — no drivers; use --sml-runtime-durable for live dispatch)")
        } else {
            print("tool audit · \(AuditLog.forProject(root: projectRoot).path)")
        }
        if let pump {
            try reportInteractiveSMLRuntimeDrain(await pump.drain())
        }

        let reader = SMLRuntimeBoundedLineReader(input: .standardInput)
        while true {
            let pendingSuffix = try await pendingPromptSuffix(host)
            FileHandle.standardOutput.write(Data("sml(\(workflowID))\(pendingSuffix) ❯ ".utf8))
            guard let raw = try reader.readLine() else {
                print("")  // EOF: leave cleanly on the ctrl-d line
                return 0
            }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            do {
                let response = try await session.submit(line)
                if !response.output.isEmpty {
                    print(response.output)
                }
                if response.shouldExit {
                    return 0
                }
            } catch {
                print("error: \(error)")
                continue
            }
            if let pump {
                try reportInteractiveSMLRuntimeDrain(await pump.drain())
            }
        }
    }

    private static func reportInteractiveSMLRuntimeDrain(
        _ report: SMLRuntimeCapabilityPump.DrainReport
    ) throws {
        if report.hostFailure != nil {
            throw SMLRuntimeInteractiveREPLError.durableStoreUnavailable
        }
        for taskID in report.dispatched {
            print("· dispatched capability for \(taskID)")
        }
        for taskID in report.failed.keys.sorted() {
            print("· dispatch failed for \(taskID); inspect its durable receipts and host config")
        }
    }

    /// `[N pending]` when the durable store has human-actionable work; empty otherwise.
    private static func pendingPromptSuffix(_ host: SMLRuntimeHostLaunch) async throws -> String {
        guard let environment = host.durableEnvironment else { return "" }
        let snapshot = try await environment.store.load()
        let view = SMLRuntimePendingView.build(from: snapshot)
        let pending = view.approvals.count + view.capabilities.count + view.stuckClaims.count
        return pending > 0 ? " [\(pending) pending]" : ""
    }
}

final class SMLRuntimeBoundedLineReader {
    static let maximumLineBytes = 65_536

    private let input: FileHandle
    private var buffer = Data()

    init(input: FileHandle) {
        self.input = input
    }

    func readLine() throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return try decode(line)
            }
            guard buffer.count <= Self.maximumLineBytes else {
                throw SMLRuntimeInteractiveREPLError.inputTooLarge(Self.maximumLineBytes)
            }
            let remaining = Self.maximumLineBytes - buffer.count + 1
            guard let chunk = try input.read(upToCount: min(4_096, remaining)),
                  !chunk.isEmpty else {
                guard !buffer.isEmpty else { return nil }
                let final = buffer
                buffer.removeAll(keepingCapacity: true)
                return try decode(final)
            }
            buffer.append(chunk)
        }
    }

    private func decode(_ bytes: Data) throws -> String {
        guard bytes.count <= Self.maximumLineBytes else {
            throw SMLRuntimeInteractiveREPLError.inputTooLarge(Self.maximumLineBytes)
        }
        var normalized = bytes
        if normalized.last == 0x0D { normalized.removeLast() }
        guard let line = String(data: normalized, encoding: .utf8) else {
            throw SMLRuntimeInteractiveREPLError.invalidUTF8
        }
        return line
    }
}

enum SMLRuntimeInteractiveREPLError: Error, CustomStringConvertible {
    case inputTooLarge(Int)
    case invalidUTF8
    case durableStoreUnavailable

    var description: String {
        switch self {
        case .inputTooLarge(let maximum):
            return "SML REPL input exceeds the \(maximum)-byte line limit"
        case .invalidUTF8:
            return "SML REPL input must be valid UTF-8"
        case .durableStoreUnavailable:
            return "SML REPL durable store became unavailable; execution stopped fail-closed"
        }
    }
}
