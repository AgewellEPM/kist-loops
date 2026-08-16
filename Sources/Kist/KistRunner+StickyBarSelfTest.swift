import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Sticky-bar TTY self-test — extracted from KistRunner.swift to keep the core orchestration file under the
// size limit. Part of `enum KistRunner`.
extension KistRunner {
    /// Real-TTY diagnostic for Terminal.app. It exercises the production descriptor capture and
    /// panel renderer for ~9 seconds, including fragmented/wrapped stdout, stderr, CR repaint,
    /// type-ahead/queue redraw, and clean DECSTBM teardown.
    static func runStickyBarSelfTest() async -> Int32 {
        guard stdinIsTTY(), isatty(fileno(stdout)) != 0 else {
            err("sticky-bar self-test requires an interactive TTY")
            return 2
        }

        print("sticky-bar diagnostic · 9s · the box must stay fixed while output streams above it")
        // Establish raw stdin ownership before the first DECSTBM activation. Otherwise a key
        // arriving between screen activation/capture and enableForWatch() is kernel-echoed
        // outside the serialized output owner.
        let raw = RawMode()
        raw.enableForWatch()
        guard raw.isActive else {
            err("sticky-bar diagnostic could not enter bounded raw-input mode")
            return 1
        }
        let bar = PinnedBar(enabled: true)
        bar.activate()
        guard bar.active else {
            raw.disable()
            err("sticky-bar diagnostic could not activate the safe coordinator")
            return 1
        }
        let panel = TerminalScreenCoordinator.Panel(
            status: "diagnostic · serialized stdout+stderr · resize the window now",
            pending: "",
            queuedCount: 0,
            hint: "offline self-test · fixed box · no model / MCP / network")
        guard bar.beginStickyTurn(panel: panel) else {
            // Release every screen artifact while stdin is still raw, then restore echo.
            bar.suspend()
            bar.deactivate()
            raw.disable()
            err("sticky-bar diagnostic could not capture process output")
            return 1
        }
        // Exercise the same raw-input state as a real submitted-message session. The tiny watcher
        // converts terminal Ctrl-C/Ctrl-\ bytes back into the corresponding process signal, so the
        // visible diagnostic remains interruptible while the PTY test can prove exact restoration.
        let interruptWatcher = Task.detached {
            while !Task.isCancelled {
                guard let byte = raw.readByteTimed() else { continue }
                if byte == 0x03 {
                    _ = kill(getpid(), SIGINT)
                } else if byte == 0x1C {
                    _ = kill(getpid(), SIGQUIT)
                }
            }
        }
        FileHandle.standardOutput.write(Data("sticky-bar diagnostic ready\n".utf8))

        let pending = ["", "t", "ty", "typ", "type", "typea", "typeahead", "typeahead 中", "typeahead 中🙂"]
        let diagnosticTicks = min(36, max(1,
            Int(ProcessInfo.processInfo.environment["KIST_STICKY_SELF_TEST_TICKS"] ?? "") ?? 36))
        for tick in 0..<diagnosticTicks {
            let word = "fragment-\(tick)"
            let split = max(1, word.utf8.count / 2)
            let bytes = Array(word.utf8)
            FileHandle.standardOutput.write(Data(bytes[..<split]))
            FileHandle.standardOutput.write(Data(bytes[split...]))
            FileHandle.standardOutput.write(Data(" · ordered stdout\n".utf8))
            if tick == 5 {
                FileHandle.standardError.write(Data("[diagnostic stderr] one ordered warning line\n".utf8))
            }
            if tick % 6 == 0 {
                let wrapped = String(repeating: "wrapped-output-🙂-中-", count: 12)
                FileHandle.standardOutput.write(Data((wrapped + "\n").utf8))
            }
            FileHandle.standardOutput.write(
                Data(("\r\u{001B}[K◇ spinner repaint \(tick + 1)/\(diagnosticTicks)").utf8))
            let typed = pending[min(pending.count - 1, tick / 4)]
            bar.updateStickyTypeahead(pending: typed, queuedCount: tick >= 24 ? 2 : (tick >= 16 ? 1 : 0))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        FileHandle.standardOutput.write(Data("\r\u{001B}[K✓ stream complete\n".utf8))
        // Release capture and DECSTBM while the watcher still owns raw stdin. Continuous
        // typeahead must never become kernel echo until the fixed panel is gone.
        bar.suspend()
        interruptWatcher.cancel()
        _ = await interruptWatcher.value
        raw.disable()
        if let delay = Int(ProcessInfo.processInfo.environment[
            "KIST_STICKY_SELF_TEST_HANDOFF_DELAY_MS"] ?? ""), delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 500)) * 1_000_000)
        }
        bar.endStickyTurn()
        bar.deactivate()
        print("sticky-bar diagnostic complete · if the box stayed fixed and the shell is normal, PASS")
        return 0
    }

}
