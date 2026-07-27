# Mythos · Multimodal + Persistent-TUI Build Plan

**Status:** PLAN (research-backed). Nothing built yet. Build order front-loads the multimodal
"drag a file, the AI sees it" win and de-risks the terminal rewrite to last.

Two goals from Luke:
1. **Drag full videos / images / sound clips into the terminal** and have Gemini (or any
   vision-capable model) interpret them — full multimodal, multi-model.
2. **A true persistent input box at the bottom** — type *while* the agent runs, send without the
   Enter-as-approve trap, single-keypress approvals, scrollback preserved. Claude-Code feel.

---

## 0. What we already have (don't rebuild)

| Capability | State | File |
|---|---|---|
| `/model` mid-session switch | ✅ shipped | `KistREPL.swift` |
| Multi-provider registry + role bindings | ✅ | `ProviderRegistry`, `RoleBindings` |
| `ChatMessage.imageData` + `imageMimeType` (single image) | ✅ partial | `Models.swift` |
| Gemini sends images as `inline_data` | ✅ | `GeminiProvider.swift` |
| Capability flag `AIModel.isVision` | ✅ | `Models.swift` |
| Approval flow (Enter=run, n=skip, a=allow-all) | ✅ just shipped | `TerminalInteractor.swift` |

**The real gaps:** (a) the loop's `turn(transcript:userInput:)` takes only a `String` — there is
*no way to attach media to a turn* even though the model could read it; (b) no video/audio; (c) no
Gemini Files API for big files; (d) no raw-mode TUI; (e) no clipboard image paste.

---

## 1. Research findings (June 2026)

### Terminal multimodal ingestion — how the real tools do it
- **Pi** (`@earendil-works/pi-tui` + `pi-ai`): drag-drop, **Ctrl+V paste**, and **`@file` fuzzy
  refs**. One-shot: `pi -p @screenshot.png "what's in this image?"`. Mid-session `/model`. A
  **differential-rendering** TUI (only redraws changed cells — key for streaming).
- **Codex CLI / Crush / Gemini CLI:** image input in-terminal; Crush (Charmbracelet/Go) pastes
  images from the clipboard + "YOLO mode". Gemini CLI does app-gen from PDFs/sketches.
- **Mechanism that matters:** dragging a file from Finder into macOS Terminal / iTerm2 / Ghostty
  **inserts the file's POSIX path as text** (quoted/escaped). We do **not** need OSC-1337 or any
  terminal image protocol for drag-drop — we just **detect media paths in the typed input**. This
  works across every terminal. (Clipboard *image data* is the separate, harder path — see §4.)

### Gemini multimodal API (the engine for video/audio)
- **Inline data:** `<100MB` total request (raised from 20MB in Jan 2026), best for short clips
  (<1 min), one-off. Base64 in the request part.
- **Files API:** for `>20MB`, video `>~1 min`, or reuse. **Resumable upload → poll until
  `state == ACTIVE` → reference `fileUri`.** Per-file 2GB free / 20GB paid; files expire 48h.
- **Sampling:** video @ **1 fps**, audio @ 1Kbps mono; ~**300 tokens/sec** default (~100 low-res).
  1M context ≈ 1h video default / 3h low-res. **One video per request** for best results.
- **Video mime:** mp4, mpeg, mov, avi, webm, wmv, 3gpp, x-flv, mpg. Audio: mp3, wav, etc.

### Swift TUI landscape (for the rewrite)
- **SwiftTUI** (rensbreur / bannzai), **TUIkit** (pure-Swift, focus mgmt + key handlers +
  status bar), **SwiftCurses** (ncurses wrapper), **Terminus** (pure ANSI). All young; most assume
  **they own the render loop**, which fights an external async token stream from the agent.
- **Decision:** **build a thin raw-mode layer ourselves** (termios + ANSI), not a framework — see
  §3 rationale. Terminus is a useful reference for the ANSI primitives.

---

## 2. Architecture decisions (the load-bearing choices)

1. **Drag-drop = path detection, not terminal protocols.** The input reader scans tokens for
   existing files with media extensions, lifts them into attachments, and strips them from the
   prompt text. Cross-terminal, zero protocol risk.
2. **Gemini is the multimodal workhorse; routing is capability-aware.** A turn carrying
   video/audio — or images when the *active* model isn't `isVision` — is transparently routed to
   Gemini for that turn, then control returns to the user's chosen model. **Disclose the borrow**
   (same honesty pattern as the MiMo→Claude Sidekick disclosure). Images may also go to Claude/other
   vision models directly.
3. **Data model: `ChatMessage.attachments: [MediaAttachment]`.** Each attachment is
   `{ kind: image|video|audio|pdf, mimeType, payload: .inline(Data) | .fileURI(String) }`. Keep
   `imageData`/`imageMimeType` as a computed back-compat shim so nothing else breaks.
4. **Build the TUI ourselves with a DECSTBM scroll-region**, not alternate-screen and not a
   framework. The bottom 2–3 rows are a pinned input box; the top region scrolls and receives
   streamed agent output; **native scrollback is preserved** (Luke can scroll up). Input is read in
   **raw mode on its own task**, fully decoupled from the agent owning stdin.
5. **The interactor stops calling `readLine`.** In TUI mode, `requestApproval` routes through the UI
   (an async channel), so approvals become **single keypress** (y / n / a — no Enter) and never
   collide with message typing. Falls back to today's line-based prompt when not a TTY / `--no-tui`.

---

## 3. Why build the TUI instead of using SwiftTUI/TUIkit

- We must **interleave a live async token stream** (the agent streaming tokens, tool lanes,
  approval requests) with a **live editable input box**. SwiftUI-in-terminal frameworks own a
  render loop and a declarative tree; pushing an external high-frequency stream through them is
  awkward and laggy.
- A **scroll-region** chat TUI is small and gives us exactly two regions (scrolling transcript +
  pinned input) while **keeping the terminal's own scrollback** — frameworks that use the alternate
  screen throw scrollback away.
- Young third-party libs = **dependency + maintenance risk** on a product path. termios + ANSI is
  stable and fully in our control.
- **Trade-off (stated honestly):** we own the hard parts — `SIGWINCH` resize, bracketed paste,
  UTF-8 grapheme width, key-escape decoding, and restoring cooked mode on every exit/crash. This is
  the riskiest phase; it ships last and isolated.

---

## 4. Phased build order (value first, risk last)

### Phase 1 — Multimodal data model + drag-an-image (works on TODAY's REPL) · SMALL
- `MediaAttachment` type + `ChatMessage.attachments` (imageData shim).
- `MediaResolver`: scan input for media file paths (unescape quotes/backslashes), classify by
  ext/mime, read inline if small. Strip paths from the prompt.
- `loop.turn(transcript:userInput:attachments:)` overload.
- GeminiProvider: encode `attachments` (image inline_data). Auto-route image turns to Gemini when
  the active model isn't vision-capable; disclose.
- **Deliverable:** drag an image into the existing line REPL → "Gemini, what is this?" works. No
  TUI needed. Tests: resolver path-parsing (quoted/escaped/multiple/non-existent), provider encode.

### Phase 2 — Video + audio + Gemini Files API · MEDIUM
- `GeminiFilesClient`: resumable upload → poll ACTIVE → `fileUri`; inline for <~20MB/<1min.
- Route video/audio attachments → Gemini, one video/request guard, token/cost pre-warn for long
  media (~300 tok/s). 48h-expiry note. Provider encodes `fileData`/inline video+audio parts.
- **Deliverable:** drag a `.mp4` / `.mov` / `.mp3` → Gemini interprets it. Tests: upload/poll state
  machine (mocked), routing, cost-warn threshold.

### Phase 3 — Capability-aware multi-provider vision + `@file` refs · MEDIUM
- `@path` fuzzy file references in the prompt (Pi-style) for explicit attach.
- Capability routing across providers (Claude/others get images; Gemini gets video/audio); honest
  disclosure of which model read the media. Per-provider encoders pinned by test.
- **Deliverable:** "any vision model interprets it," routed by capability, disclosed.

### Phase 4 — Raw-mode persistent-input TUI (the big one) · LARGE / ISOLATED
- New `Sources/Kist/TUI/` module (no monoliths): `RawMode.swift` (termios + restore-on-exit),
  `ScreenLayout.swift` (DECSTBM scroll region + SIGWINCH), `LineEditor.swift` (UTF-8, cursor,
  history, bracketed paste), `InputChannel.swift` (async input decoupled from the agent),
  `TUIEventSink.swift` (streams into the scroll region), `TUIInteractor.swift` (single-key approvals
  through the channel).
- Type **while the agent runs**; **single-keypress** approvals; live status footer (model · roles ·
  tokens · plan-mode); `--no-tui` + non-TTY fall back to today's REPL.
- **Clipboard image paste:** Ctrl+V reads `NSPasteboard` (macOS-native) → screenshot attachment.
- **Deliverable:** the Claude-Code feel. Heaviest test + manual-verify burden; ships last.

---

## 5. Risks & mitigations
- **Loop owns stdin today** (interactor `readLine`). Phase 4 must invert this: UI owns all input,
  interactor asks *through* the UI. Plan the I/O seam before writing TUI code.
- **Terminal correctness** (resize/paste/UTF-8/restore). Mitigate: isolate in `TUI/`, golden tests
  for the line editor, always restore cooked mode in a `defer` + signal handler.
- **Gemini Files API** auth/expiry/poll latency. Mitigate: state-machine tests, 48h note, retries.
- **Cost** on long video (~300 tok/s). Mitigate: pre-send size/duration estimate + confirm.
- **Parallel session editing these files.** Mitigate: build in a dedicated worktree/branch, commit
  each increment (standing rule), keep new code in new files where possible.

---

## 6. Recommendation
Start **Phase 1 now** — it's small, low-risk, touches mostly new files, and delivers the
"drag a file, the AI sees it" dream on the REPL we already have. Lock the **Phase 4 TUI approach**
(DIY raw-mode scroll-region, as argued in §3) before building it. Phases 1–3 need no terminal
rewrite, so multimodal value lands well before the risky part.

_Sources:_ Pi (dev.to/arshtechpro), Gemini video-understanding + file-input docs (ai.google.dev),
awesome-cli-coding-agents (github.com/bradAGI), SwiftTUI/TUIkit/Terminus, iTerm2/Ghostty drag-drop
threads (HN/GitHub). See chat for links.
