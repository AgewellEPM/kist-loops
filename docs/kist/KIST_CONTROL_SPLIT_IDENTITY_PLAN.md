# kist-control split-identity — implementation plan (council-vetted 2026-07-03)

The TRUE host-control boundary (Layer 2 completion). Council 5/5 + Codex.

## Why (recap)
Deny-lists can't stop in-language injection (python→CGEventPost); Seatbelt can't cleanly deny the capability;
a child of a TCC-granted `kist` INHERITS the grant (confirmed). The only robust fix: the coding binary NEVER
holds Accessibility/Screen-Recording, and a SEPARATE signed binary does — reachable only via authenticated IPC.

## Architecture (council-agreed)
- **`kist`** (coding CLI): shell/MCP/build/python/custom_tool. MUST never request/hold AX/Screen/Automation TCC.
- **`kist-control`** (distinct bundle id `com.kist.control`): the ONLY binary the user grants TCC. Owns the
  CG/AX/CGDisplayCreateImage primitives (moved out of DesktopControlTool). Runs NO shell/python/MCP/build.
  Launched INDEPENDENTLY (LaunchAgent / login-item), NEVER spawned by kist (spawning ⇒ inherited/fragile TCC).
- **--enable-computer-use** opens an authenticated IPC session to the already-running broker.

## Transport DECISION: Unix-domain socket FIRST (Codex — SwiftPM-shippable, no .app packaging), XPC as the
## hardened v2 (4 API models — native audit-token auth, launchd lifecycle) once .app packaging + signing exist.
The protocol contract is transport-agnostic, so the transport can upgrade without touching the message schema.
- Socket at `~/Library/Application Support/kist/control.sock`, dir 0700, socket 0600.

## Peer AUTHENTICATION (security-critical — "socket path is not auth")
On accept: require same uid; get the peer audit token (`LOCAL_PEERTOKEN`); build a `SecCode` via
`kSecGuestAttributeAudit`; `SecCodeCheckValidity` against the PINNED `kist` designated requirement (identifier
com.kist.cli + team/anchor). kist likewise verifies the broker's requirement. Reject everything else →
`unauthorizedPeer`. Dev fallback (unsigned): a cdhash+path allowlist paired via `kist-control pair <path>`.

## SHIPPED NOW (this change — real, unit-tested, transport-agnostic)
- `Sources/AgentCore/DesktopControl/KistControlProtocol.swift`: the IPC CONTRACT — DesktopActionRequest/
  Response/ErrorCode + per-kind TCC needs + length-prefixed framing (fail-closed on oversize). 5 tests.

## REMAINING (signing + hardware gated — NOT buildable/verifiable in a dev sandbox)
1. Extract DesktopControlTool's CG/AX primitives behind a `DesktopActuator` protocol; move the real impl into
   the `kist-control` executable target; DesktopControlTool becomes an IPC client (armed path only).
2. SPM `executableTarget("kist-control")` + UDS server + the audit-token/SecCode peer verifier (macOS).
3. LaunchAgent plist + a tiny installer + "TCC hygiene" doc/command.
4. Signing: two distinct code-signing identities/bundle ids.
5. **MANDATORY hardware verification (Codex): mandatory before shipping.** Reset TCC. Grant ONLY kist-control.
   Prove: unarmed kist + its python child CANNOT inject (AXIsProcessTrusted false, CGEvent no-op); kist-control
   self-test CAN move cursor + capture a non-uniform frame; `kist --enable-computer-use` succeeds only via the
   broker; an unsigned/different-signed local client is REJECTED. Then temporarily grant kist, prove its python
   child CAN inject, reset — closing the loop that the split is what makes the difference.

## Biggest risk (council): Apple's undocumented responsible-process/TCC attribution across launch styles →
## the hardware test is non-negotiable; and distribution UX (a CLI needing a separate granted binary) needs
## crystal-clear install guidance.

## LABEL: contract = PILOT-READY (tested). The boundary is NOT real until 1–5 land + the hardware test passes.
