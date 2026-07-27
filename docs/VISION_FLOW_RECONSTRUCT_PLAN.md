# Vision-Driven App Reconstruction — Plan (screenshot-to-app with visual confirmation)

Luke's idea: Gemini drives the app, screenshots every screen + transition, builds a visual flow map, then
regenerates a working app that matches — and a CLOSED LOOP screenshots the rebuild and has Gemini compare
it to the original until they visually match. "Rebuild it exactly, confirmed by image."

This is the VISUAL variant of Stage 2 (Reconstruct) in `APP_RECONSTRUCT_HARDEN_PLAN.md` — use it when you
want fidelity to the *appearance/flow* (redesign, migration, rebuild), not source recovery.

---

## What we already have (so this is wiring, not invention)
- **`BrowserTool`/Playwright** — drives web apps: navigate, click, type, screenshot, read DOM.
- **`os_screenshot` / tinky-vision MCP** — screenshots native/desktop apps.
- **Gemini vision** (`AnalyzeMediaTool`; + `view_image` from Wave 1.3) — interprets images into structure.
- **tinky-verify** — Gemini drives a page AND judges it visually with hard evidence. THE pattern for the
  confirmation loop, already proven.
- **`apply_patch` / `write_file`** (Wave 1.2) — generate the rebuild's code.
- Worktree + sandbox (isolate the rebuild), council/captain (verify), the authorization scope guardrail.

**THE GAP**: a flow-capture orchestrator, screenshot→UI-spec, spec→code generation, and the visual-diff
confirmation loop that ties them together.

---

## Pipeline — 4 stages

### V1 — CAPTURE THE FLOW
- Drive the app (BrowserTool for web; `os_screenshot` for native). Explore the navigation graph: at each
  state, screenshot it AND record the action that produced it (click element X / type Y → next screen).
  Bounded BFS over interactive elements (depth/visit caps — never a runaway crawl).
- Output: a **flow graph** — nodes = screens (screenshots), edges = actions (transitions).

### V2 — INTERPRET (Gemini vision → structured UI spec)
- Each screenshot → Gemini → a STRUCTURED spec: layout regions, components (buttons/inputs/lists/nav/cards),
  text content, colors, typography, spacing. Multi-image context so it understands the whole flow, not just
  one screen.
- Output: per-screen UI spec + the navigation model.

### V3 — GENERATE (spec → working app)
- From the specs + flow graph, generate a runnable app for a chosen target stack (web: React/HTML+CSS;
  native: SwiftUI) with each screen + navigation matching the captured flow. Scaffold via `write_file` /
  `apply_patch` into the sandbox.
- Output: a buildable, runnable rebuild that LOOKS like the original.

### V4 — VISUAL CONFIRMATION LOOP  ← the headline ("exact based on visual confirmation")
- Build + run the generated app in the sandbox → screenshot the SAME flow (re-drive it).
- Gemini compares rebuild-screenshot vs original-screenshot, **per screen** → a fidelity verdict + a concrete
  diff of what's off (missing button, wrong color, layout shift, wrong copy). This reuses the tinky-verify
  judge shape (hard evidence + skeptical visual look — never a fabricated "looks good").
- Feed the diffs back → the generator patches the code (`apply_patch`) → re-screenshot → re-compare.
- **Iterate until the visual match crosses a threshold OR a round cap.** This loop is what turns "kind of
  looks like it" into "converged to the original by image."

---

## Honest limits (stated up front, not buried)
- Recovers **UI / UX / appearance + client navigation** — NOT backend logic, real data, auth, or original
  source. You get a visually faithful, runnable *shell*. (For real source you still need the repo or the
  client-bundle mirror from the other plan.)
- **"Exact" = visually convergent via the loop**, not guaranteed pixel-perfect; the loop drives it toward
  fidelity and reports the residual diff honestly. No "100% identical" claim it can't back with a screenshot.
- **Authorization scope STILL applies.** Capturing/cloning an app's look is a trade-dress/copyright matter
  as well as CFAA — so this targets apps you OWN or are authorized to rebuild (your Tinky/TinkySpeak
  properties, your own designs, a redesign of your own app). Same `.kist/security-scope.json` gate.

---

## Dependencies + order
- **PREREQ: Wave 1.3 `view_image`** (Gemini must read still screenshots, not just A/V) — this plan makes
  view_image a real priority.
1. `view_image` (Wave 1.3).
2. V1 flow-capture orchestrator (BrowserTool nav-graph + screenshot-per-state).
3. V2 Gemini screenshot→UI-spec.
4. V3 spec→code generation (ONE target stack first — web is easiest to screenshot+rebuild).
5. V4 visual-diff confirmation loop (built on the tinky-verify judge).
Each: build → test → adversarial Codex → ff-merge. Capture/clone gated by the authorization scope.

## One-paragraph framing
You already have the drive-and-screenshot half (BrowserTool, os_screenshot) and the judge half (Gemini
vision + the tinky-verify visual verifier). This plan adds the three connective pieces — capture a flow
graph, turn screenshots into a UI spec, generate the app — and then closes the loop: screenshot the rebuild,
let Gemini diff it against the original, patch, repeat until it matches. It's the visual sibling of the
code-mirror reconstruction: that one recovers the bytes, this one recovers the look-and-flow, and the
confirmation loop is what makes "rebuild it exactly by image" a real, measurable thing instead of a vibe.
