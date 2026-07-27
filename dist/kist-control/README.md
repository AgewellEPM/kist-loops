# kist-control — the privileged desktop broker (split-identity L2)

`kist-control` is the ONLY binary the user grants Accessibility / Screen-Recording. The coding `kist` never
holds those grants, so an unarmed agent (or its `python` child) CANNOT drive the desktop — the OS TCC boundary
enforces it. `kist --enable-computer-use` sends discrete, AUTHENTICATED actions to the broker over a
Unix-domain socket; the broker performs them with its own grant. See ../../docs/kist/KIST_CONTROL_SPLIT_IDENTITY_PLAN.md.

## Status of THIS build
- Broker binary, IPC contract, auth gates (BrokerCore), UDS transport, real CGEvent actuator, and the
  audit-token→SecCode peer verifier are BUILT + logic-tested.
- The TCC-separation SECURITY PROPERTY is REAL only once both binaries are separately CODE-SIGNED (distinct
  bundle ids com.kist.cli / com.kist.control) and the agent is granted TCC — VERIFIED ON HARDWARE (below).

## Install (signed build)
1. Sign `kist` (com.kist.cli) and `kist-control` (com.kist.control) with your identity.
2. Install `kist-control` (e.g. /usr/local/bin) + this plist to ~/Library/LaunchAgents/com.kist.control.plist.
3. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kist.control.plist`
4. Grant com.kist.control Accessibility + Screen Recording in System Settings ▸ Privacy & Security.
5. Do NOT grant kist (or your terminal) those permissions. `kist --enable-computer-use` will now work via the broker.

## MANDATORY hardware verification (before trusting the boundary)
- `tccutil reset Accessibility com.kist.cli` (ensure kist has no grant).
- Prove UNARMED kist + a `python -c 'import Quartz; ...CGEventPost...'` child CANNOT move the cursor.
- Prove `kist-control --self-test` (and an armed brokered click) CAN.
- Prove a rogue local process connecting to the socket is REJECTED (fails the pinned code requirement).
- Then temporarily grant kist Accessibility, prove its python child CAN inject, reset — showing the split is
  what makes the difference.

## Dev (unsigned) — for wiring tests only, NOT a security boundary
`kist-control --dev-trust-same-uid --socket /tmp/kc.sock` trusts any same-uid peer (prints a warning). Never ship this.
