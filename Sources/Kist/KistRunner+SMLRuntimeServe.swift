import Foundation
import AgentCore

/// `kist --sml-runtime-serve <source.json>` — the long-lived harness milestone: a durable,
/// approval-gated SML workflow runtime served over loopback HTTP.
///
/// Assembly (every piece host-owned): durable environment (persistent store, real clock,
/// deny-by-default authority, exclusive host lock) → approval-gated workflows (injected at load)
/// → production capability drivers built from the human catalog → single-flight capability pump →
/// loopback HTTP core with a per-session bearer token. An approval POSTed to the generated
/// `.../tasks/{id}/approve` route is followed immediately by its gated dispatch; SIGINT/SIGTERM
/// stop accepting, let the single in-flight dispatch finish, and release the host lock.
extension KistRunner {
    static func runSMLRuntimeServe(_ opts: KistOptions) async -> Int32 {
        do {
            return try await withSMLRuntimeHostLaunch(
                sourcePath: opts.smlRuntimeServe,
                projectRoot: opts.project,
                mode: .durable,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            ) { host in
                try await serveLaunchedRuntime(host, opts: opts)
            }
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    private static func serveLaunchedRuntime(
        _ host: SMLRuntimeHostLaunch,
        opts: KistOptions
    ) async throws -> Int32 {
        guard let environment = host.durableEnvironment,
              host.durableRuntime != nil else {
            err("error: serve mode requires the durable host launch")
            return 2
        }
        let projectRoot = opts.project
        let actor = opts.smlRuntimeActor ?? "sml-runtime-exporter"

        return try await withSMLRuntimeCapabilityStack(
            host: host,
            projectRoot: projectRoot,
            actor: actor,
            enableComputerUse: opts.enableComputerUse
        ) { capabilityStack in
            try await serveLaunchedRuntime(
                host,
                environment: environment,
                capabilityStack: capabilityStack,
                opts: opts
            )
        }
    }

    private static func serveLaunchedRuntime(
        _ host: SMLRuntimeHostLaunch,
        environment: SMLRuntimeDurableHostEnvironment,
        capabilityStack: SMLRuntimeCapabilityStack,
        opts: KistOptions
    ) async throws -> Int32 {
        let projectRoot = opts.project
        let gateway = capabilityStack.gateway
        let pump = capabilityStack.pump

        let api = host.launch.registry.makeAPI(
            gateway: gateway,
            authorityResolver: environment.authorityResolver,
            launchDescriptor: host.launch.app.launchDescriptor,
            clock: environment.clock
        )
        let tokenURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".kist/sml/serve/session-token")
        let token = try SMLRuntimeHTTPCore.mintSessionToken(writingTo: tokenURL)
        defer {
            do {
                try SMLRuntimeHTTPCore.removeSessionToken(at: tokenURL)
            } catch {
                err(
                    "warning: could not remove the SML runtime session token; "
                        + "remove \(tokenURL.path) before restarting"
                )
            }
        }
        let portRange: ClosedRange<UInt16>
        if let requested = opts.smlRuntimeServePort {
            portRange = requested...requested
        } else {
            portRange = 8850...8880
        }
        let core = SMLRuntimeHTTPCore(
            api: api,
            store: environment.store,
            pump: pump,
            sessionToken: token,
            configuration: SMLRuntimeHTTPCore.Configuration(portRange: portRange)
        )
        let termination = SMLRuntimeTerminationSignal()
        defer { termination.close() }
        guard let url = core.start() else {
            err("error: no free loopback port in \(portRange)")
            return 2
        }

        print("sml runtime serving \(url)")
        print("  source: \(host.sourcePath)")
        print("  workflows: \(host.runtimePackage.workflowIDs.sorted().joined(separator: ", "))")
        print("  session token: \(tokenURL.path)")
        print("  tool audit: \(AuditLog.forProject(root: projectRoot).path)")
        print("  pending work: GET /approvals · approve: POST <api>/tasks/<id>/approve")
        print("  stop: ctrl-c (drains in-flight work, releases the host lock)")

        // Install signal handling before dispatching resumed work, and keep observation responsive.
        await pump.requestDrain()
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                await pump.requestDrain()
            }
        }
        await termination.wait()
        termination.close() // Further Ctrl-C/SIGTERM can interrupt a slow shutdown.
        ticker.cancel()
        core.stop()
        if !(await pump.shutdown()) {
            err("warning: SML dispatch did not finish within the shutdown grace; its claim remains pending")
        }
        print("sml runtime stopped")
        return 0
    }

    static func reportSMLRuntimeDrain(_ report: SMLRuntimeCapabilityPump.DrainReport) {
        if report.hostFailure != nil {
            err("warning: SML capability pump could not read the durable store")
        }
        for taskID in report.failed.keys.sorted() {
            err("warning: SML capability dispatch failed for \(taskID); inspect its durable receipts")
        }
    }

}

/// The signal can arrive before wait() begins; retain it until the host starts waiting.
private final class SMLRuntimeTerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var closed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []

    init() {
        let queue = DispatchQueue(label: "sml-serve-signals")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.fire() }
            sources.append(source)
            source.resume()
        }
    }

    private func fire() {
        lock.lock()
        fired = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { pending in
            lock.lock()
            if fired {
                lock.unlock()
                pending.resume()
            } else {
                continuation = pending
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let active = sources
        sources = []
        lock.unlock()
        for source in active { source.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
