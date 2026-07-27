# Host-control = hard capability gate (deny-without-arming), not approval-dependent

Council 2026-07-03 (DeepSeek+GPT-5+Grok+Gemini+Codex). Follows the computer-use TOOL default-deny
(already shipped: desktop tools registered only under --enable-computer-use). This closes the remaining
NON-tool host-control routes.

## LAYER 1 — SHIPPED (this change). Direct + MCP + nested, hard-denied unless armed.
- **Shell (G1/G3):** `ShellPolicy.hostControlDeny` (osascript/osacompile/cliclick/screencapture/automator/
  shortcuts/system events/open -a/open shortcuts:|applescript:/ffmpeg -f avfoundation/imagesnap/hidutil/
  cgsession/launchctl/defaults write/pbcopy/pbpaste) is appended to the shell `deny` list when
  `!enableComputerUse`. Enforced by `binaryRefusalReason` = UN-BYPASSABLE against token tricks and
  INDEPENDENT of the interactor (so --auto/--yolo/AutoApprove cannot run them). Nested kist forces
  enableComputerUse=false ⇒ covered with no allowShell change. Armed ⇒ normal .dangerous approval.
- **MCP (G2):** host-control-verb MCP tools (click/type/screenshot/…) dropped from the registry when
  `!enableComputerUse`. Targeted by verb so non-desktop MCP (github/db/fs) keeps working unarmed.
- Council unanimous: do NOT globally deny .dangerous in AutoApprove (breaks legit sandboxed --auto file
  ops); the hard deny-list is the correct interactor-independent gate.

## LAYER 2 — REQUIRED for a TRUE hard gate (NOT yet done; documented honestly).
Codex + GPT-5 + DeepSeek + Grok: a deny-list catches DIRECT argv, NOT descendants / in-language API abuse:
`python script.py` or a compiled binary calling `CGEventPost`/`AXUIElement`/`CGWindowList`, `npm test`
spawning automation, etc. Interpreters are deliberately NOT denied (a coding agent needs python/node).
The only complete fix is OS-LEVEL CAPABILITY DENIAL for unarmed runs:
- macOS: a Seatbelt profile (or a TCC-denied helper/container) that denies AppleEvents
  (`mach-lookup com.apple.coreservices.appleevents`), Accessibility, and screen-capture to the whole job
  tree when `!enableComputerUse`. Feasibility caveats to resolve: CGEventPost is TCC-Accessibility-gated
  (per-app), not classic Seatbelt — needs research on whether sandbox-exec can deny it, or whether an
  unarmed arbitrary-code helper must run without the Accessibility TCC grant.
- **Practical backstop TODAY:** in-language injection only works if the user already granted kist
  Accessibility (a computer-use user). Non-computer-use users are protected by the OS TCC grant they never
  gave. So layer 1 + TCC covers the majority; layer 2 closes the armed-machine in-language residual.
This is a dedicated macOS-security piece with real feasibility questions — its own council + Codex pass.

## HONEST LABEL: layer 1 is PILOT-READY defense-in-depth (direct/MCP/nested hard-gated). It is NOT a
## complete host-control boundary until layer 2 lands. Do not claim otherwise.

---
## LAYER 2 — DECISION (2026-07-03, council UNANIMOUS 5/5 incl. Codex, after empirical macOS testing)

**Seatbelt L2 is NOT viable — do not build it.** Empirically: `(deny mach-lookup)` (ALL mach) blocks
screencapture but breaks legit builds (XPC/notifications); the obvious named services (windowserver/
screencapture/screencapturekit) do NOT block it; the real service is undocumented + version-fragile and
not readily derivable. Keep Seatbelt for file/network/secret confinement only — NOT host-control.

**TCC is the real boundary — but "tell users not to grant" is insufficient alone**, because a child process
INHERITS the responsible-parent's TCC grant (confirmed by Codex/Grok/GPT-5; DeepSeek's "distinct helper
auto-loses it" was corrected). So if the coding binary can ever hold Accessibility/Screen-Recording, an
agent's `python`/compiled child can drive the desktop regardless of any deny-list.

### THE ROBUST FIX (product-level, spec'd — not yet built): split-identity
- `kist` (coding CLI, e.g. bundle com.kist.cli): shell/MCP/build/python/custom_tool. MUST NEVER hold
  Accessibility/Screen-Recording/Automation grants.
- `kist-control` / `Kist Control.app` (bundle com.kist.cli.control): the ONLY binary the user grants TCC.
  Exposes ONLY narrow desktop APIs (capture, AX read/press, mouse/key) over local IPC/XPC. Runs NO shell,
  python, node, build tools, custom_tool, or MCP. `--enable-computer-use` opens a short-lived authorized IPC
  session to it. This makes unattended host-control by an unarmed agent ARCHITECTURALLY IMPOSSIBLE.
- Ship a "TCC hygiene" doc/command to reset grants for the coding binary.

### SHIPPED NOW (this change) — the tractable runtime guardrail
`HostControlPreflight`: on an UNARMED run, if THIS process already holds Accessibility/Screen-Recording, kist
prints a loud stderr WARNING (revoke it / use a dedicated binary / --enable-computer-use to arm). It DETECTS
the exact dangerous state; it is a WARNING, not containment. Honest label: defense-in-depth, not a boundary.

### STATUS: L1 (shell+MCP deny) + L2-guardrail (grant preflight) shipped. The split-identity binary is the
### required completion for a true host-control boundary — a dedicated product/packaging project.
