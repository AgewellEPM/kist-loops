import Foundation
import AgentCore

// PROTOTYPE — host_snapshot CLI mode (SECURITY BOUNDARY: exposes the macOS screen to a guest VM).
// This is a FIXED CLI subcommand, deliberately NOT a model-callable tool: a guest asks the host for a
// frame over a token-gated channel, it does not get a general screen-capture capability in the tool set.
//
// Subcommands:
//   `host-snapshot`            → one signed frame.
//   `host-snapshot --stream`   → NDJSON of independently-signed frames.
//   `host-snapshot --pubkey`   → print ONLY the Ed25519 PUBLIC key (base64) + key_id. NO token, NO frame —
//                                the operator pins this into the guest OUT-OF-BAND so the guest can verify.
//
// Flow (single frame and stream both): auth → acquire (freshness/byte/timeout bounded) → sign → emit ONE
// COMPLETE NDJSON line → exit code. Fail-closed everywhere: any failure emits a complete error object with
// a non-zero exit and ZERO captured bytes. The token is never logged and never placed in the response.
//
// "ATOMIC" MEANS LINE-ATOMIC, NOT PIPE-READ-ATOMIC: every emitted line is exactly one complete object plus a
// trailing '\n', but for a large base64 frame the OS may deliver that line to a reader across several reads.
// The consumer MUST buffer stdout until a '\n' before parsing; a partial (newline-less) line is never a
// valid object. One complete object per newline is the contract — not "one read == one object".
//
// TWO signatures on each frame: `signature` = HMAC-SHA256 (host-side integrity/provenance tag, NOT guest-
// verifiable — symmetric); `ed25519`+`key_id` = the GUEST-VERIFIABLE authenticity signature (asymmetric,
// verified against the pinned public key). REPLAY: `captured_at` is the host's self-reported wall-clock —
// no independent temporal assurance. The ONLY replay defense is a client `--nonce`: the guest plants a
// fresh random nonce per request and rejects any frame whose echoed `nonce` != the one it planted.
//
// AUTH ORACLE: every auth failure returns ONE opaque guest-facing reason ("authorization failed"); the
// specific cause (not-configured / missing / mismatch) is logged to STDERR for the operator only.
//
// Exit codes (contract): 0 ok · 2 auth failure · 3 timeout · 4 oversized · 5 stale/missing/other source.
extension KistRunner {

    /// Emit-to-stdout sink. JSON goes to STDOUT (parseable), diagnostics stay on STDERR via `err()`.
    ///
    /// CONTRACT (be precise — the "atomic" claim is at the LINE level, not the pipe-read level): each call
    /// writes exactly one complete NDJSON object followed by a single '\n'. For a large base64 frame the
    /// underlying `FileHandle.write` may deliver the line to a reader in MULTIPLE chunks, so a single `read()`
    /// on the consumer side can observe a PARTIAL line. The guarantee is: ONE complete object per newline,
    /// and a partial (newline-less) line is NEVER a valid object. The consumer MUST buffer stdout until it
    /// sees a '\n' before parsing — it must not attempt to parse whatever a single read returned.
    private static func emitLine(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    // MARK: - Single frame

    static func runHostSnapshot(_ opts: KistOptions) async -> Int32 {
        await runHostSnapshot(opts, source: HostSnapshotSource(), emit: emitLine)
    }

    /// Testable core: injected source + emit sink. Returns the process exit code.
    static func runHostSnapshot(_ opts: KistOptions,
                                source: HostSnapshotSource,
                                emit: (String) -> Void) async -> Int32 {
        // 0. `--pubkey`: print ONLY the guest-verifiable Ed25519 public key + key_id and exit. This needs
        //    NO auth token (the public key is not a secret) and captures NO frame — it exists so the
        //    operator can pin the key into the guest OUT-OF-BAND.
        if opts.hostSnapshotPubkey { return emitPubkey(emit: emit) }

        // 0b. Flag-parse validation BEFORE auth/capture: a `--display`/`--fps`/`--max-frames` value that was
        //     PRESENT but not an integer is a fail-closed atomic error (never proceed on display 0 / default
        //     rate). Emitted here (not in KistOptions) so the guest gets the kist-cli-json-v1 shape + exit 5.
        if let (line, code) = numericFlagParseError(opts) { emit(line); return code }

        // 1. Auth FIRST — before a single byte is captured. On rejection the guest sees ONE opaque reason;
        //    the specific cause goes to STDERR (operator diagnostics), never into the guest-facing JSON.
        if case let .rejected(rej) = authorizeThisInvocation(opts) {
            err("host-snapshot: authorization rejected — \(rej.internalReason)")
            emit(HostSnapshotFrame.errorLine(rej.guestReason))
            return 2
        }

        // 2. Acquire (bounded, fail-closed) → 3. sign → 4. emit atomic object.
        // Pass the RAW requested index through — NO `max(..., 0)` clamp. A negative index must fail closed
        // (HostSnapshotSource.acquire rejects `< 0` with .invalidDisplayIndex), never silently capture 0.
        let displayIndex = opts.displayIndex ?? 0
        let (line, code) = await captureAndSignLine(source: source, displayIndex: displayIndex,
                                                    nonce: opts.hostSnapshotNonce ?? "")
        emit(line)
        return code
    }

    /// If a host-snapshot numeric flag was given a PRESENT-but-non-integer value, return the atomic error
    /// line + exit code to emit BEFORE any auth or capture. `--display` is the required fix (a non-int must
    /// never silently capture display 0); `--fps`/`--max-frames` are treated the same way for consistency.
    /// Returns nil when every provided numeric flag parsed cleanly. Exit 5 (source/other) matches the
    /// invalid-display-index error code already used when `HostSnapshotSource` rejects a bad index.
    private static func numericFlagParseError(_ opts: KistOptions) -> (String, Int32)? {
        if opts.hostSnapshotDisplayParseError { return (HostSnapshotFrame.errorLine("invalid --display index"), 5) }
        if opts.hostSnapshotFpsParseError { return (HostSnapshotFrame.errorLine("invalid --fps"), 5) }
        if opts.hostSnapshotMaxFramesParseError { return (HostSnapshotFrame.errorLine("invalid --max-frames"), 5) }
        return nil
    }

    /// Resolve+authorize this invocation's credential. Factored out so single-frame and stream share the
    /// EXACT same gate (identical guest-facing reason on every failure state, per the auth-oracle fix).
    private static func authorizeThisInvocation(_ opts: KistOptions) -> HostSnapshotAuth.Decision {
        let expected = ProcessInfo.processInfo.environment[HostSnapshotAuth.tokenEnvVar]
        let supplied = HostSnapshotAuth.suppliedToken(flag: opts.authToken,
                                                      env: ProcessInfo.processInfo.environment)
        return HostSnapshotAuth.authorize(expected: expected, supplied: supplied)
    }

    /// Emit the host_snapshot Ed25519 PUBLIC key (base64) + key_id as a single atomic JSON line. No token,
    /// no frame. Fail-closed: if key material can't be produced, emit an atomic error (exit 5).
    static func emitPubkey(emit: (String) -> Void) -> Int32 {
        guard let pubB64 = try? HostSnapshotSigner.publicKeyBase64(),
              let keyID = try? HostSnapshotSigner.keyID() else {
            emit(HostSnapshotFrame.errorLine("unable to load host_snapshot Ed25519 key material"))
            return 5
        }
        emit(HostSnapshotFrame.pubkeyLine(publicKeyB64: pubB64, keyID: keyID))
        return 0
    }

    // MARK: - Stream (NDJSON)

    static func runHostSnapshotStream(_ opts: KistOptions) async -> Int32 {
        await runHostSnapshotStream(opts, source: HostSnapshotSource(), emit: emitLine,
                                    sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
    }

    /// Testable core for the stream: injected source + emit sink + sleep. Each emitted line is an
    /// independently complete AND independently signed object. On the first per-frame error, emit one
    /// atomic error line and STOP (never a partial stream that implies more is coming).
    static func runHostSnapshotStream(_ opts: KistOptions,
                                      source: HostSnapshotSource,
                                      emit: (String) -> Void,
                                      sleep: (Double) async -> Void) async -> Int32 {
        // Flag-parse validation BEFORE auth/capture (same as the single-frame path): a present-but-non-integer
        // --display/--fps/--max-frames is a fail-closed atomic error, never a silent proceed.
        if let (line, code) = numericFlagParseError(opts) { emit(line); return code }

        // Same opaque-guest-reason auth gate as the single-frame path (auth-oracle fix). Internal cause →
        // STDERR only; guest sees the one opaque reason.
        if case let .rejected(rej) = authorizeThisInvocation(opts) {
            err("host-snapshot stream: authorization rejected — \(rej.internalReason)")
            emit(HostSnapshotFrame.errorLine(rej.guestReason))
            return 2
        }

        let fps = min(max(opts.fps ?? 1, 1), 5)                 // clamp 1..5
        let maxFrames = min(max(opts.maxFrames ?? 300, 1), 300) // hard-cap 300
        let interval = 1.0 / Double(fps)
        // RAW requested index — NO `max(..., 0)` clamp; a negative index fails closed in acquire().
        let displayIndex = opts.displayIndex ?? 0
        let nonce = opts.hostSnapshotNonce ?? ""

        for i in 0..<maxFrames {
            let (line, code) = await captureAndSignLine(source: source, displayIndex: displayIndex, nonce: nonce)
            emit(line)
            if code != 0 { return code }   // per-frame error already emitted atomically; stop.
            if i < maxFrames - 1 { await sleep(interval) }
        }
        return 0
    }

    // MARK: - Shared capture→sign→line

    /// Acquire one frame, sign it, and return (atomic JSON line, exit code). Never returns a partial
    /// object: it's either a complete signed frame line or a complete error line. Exit codes map the
    /// acquisition failure so a guest can distinguish "stale desktop" from "auth" from "too big".
    ///
    /// Signs the CAPTURED display index (`acq.capturedDisplayIndex`), never the merely-requested one, so a
    /// frame can never be labeled with a display it didn't capture. The `nonce` (empty when the caller
    /// planted none) is covered by BOTH signatures and echoed in the JSON — the guest's replay defense.
    private static func captureAndSignLine(source: HostSnapshotSource, displayIndex: Int,
                                           nonce: String) async -> (String, Int32) {
        let captured = ISO8601DateFormatter.hostSnapshotUTC.string(from: Date())
        switch await source.acquire(displayIndex: displayIndex) {
        case let .success(acq):
            let displayCount = Self.liveDisplayCount()
            // Fail-closed: `signed()` returns nil when EITHER key (ForgeSeal HMAC or host_snapshot Ed25519)
            // is unavailable — we refuse to emit an unsigned/half-signed frame. The frame carries the
            // host-side HMAC integrity tag AND the guest-verifiable Ed25519 authenticity signature.
            guard let frame = HostSnapshotFrame.signed(
                    pngBytes: acq.pngBytes, capturedAt: captured, source: acq.source,
                    displayIndex: acq.capturedDisplayIndex, displayCount: displayCount,
                    width: acq.width, height: acq.height, nonce: nonce) else {
                err("host-snapshot: refused to emit frame — missing key material (ForgeSeal HMAC and/or host_snapshot Ed25519)")
                return (HostSnapshotFrame.errorLine("unable to sign frame (no key material)"), 5)
            }
            return (frame.jsonLine(), 0)
        case let .failure(e):
            return errorLineAndCode(for: e)
        }
    }

    private static func errorLineAndCode(for e: HostSnapshotSource.AcquireError) -> (String, Int32) {
        switch e {
        case .staleFrameSource:      return (HostSnapshotFrame.errorLine("stale frame source"), 5)
        case .missingFrameSource:    return (HostSnapshotFrame.errorLine("missing frame source"), 5)
        case .oversized:             return (HostSnapshotFrame.errorLine("frame exceeds 8 MiB byte cap"), 4)
        case .timedOut:              return (HostSnapshotFrame.errorLine("frame capture timed out"), 3)
        case let .conversionFailed(m): return (HostSnapshotFrame.errorLine("frame conversion failed: \(m)"), 5)
        case let .decodeFailed(m):   return (HostSnapshotFrame.errorLine("frame decode failed: \(m)"), 5)
        case .invalidDisplayIndex:   return (HostSnapshotFrame.errorLine("invalid --display index"), 5)
        case .displayNotCapturable:  return (HostSnapshotFrame.errorLine("requested display cannot be captured on this source (would mislabel the frame)"), 5)
        }
    }

    /// Live attached-display count (macOS). 1 when it can't be determined — never 0 (a frame implies a
    /// display). Kept behind DisplayGeometry so the acquisition path stays pure/testable.
    private static func liveDisplayCount() -> Int {
        #if canImport(CoreGraphics)
        let n = DisplayGeometry.liveDisplays().count
        return n > 0 ? n : 1
        #else
        return 1
        #endif
    }
}

private extension ISO8601DateFormatter {
    /// ISO8601 in UTC with a trailing `Z` — the `captured_at` format the signature binds.
    static let hostSnapshotUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
