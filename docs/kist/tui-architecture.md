# Kist — Terminal UI Architecture

> **Status: SPEC / PROTOTYPE-target.** Research + decision-ready design only. No code in this doc.
> Kist is a Claude-Code-style interactive terminal agent that runs the FloatingChatApp
> agent system entirely in a terminal, built **on top of `AgentCore`** (Foundation-only,
> cross-platform). Type `Kist`, get an interactive TUI agent driving all 10 providers.

## 0. Constraints that drive every decision

These come from the existing `AgentCore` library and are non-negotiable:

- **Cross-platform: macOS AND Linux headless.** Kist is a Swift executable that must build and
  run on Linux with no Apple frameworks. AgentCore already enforces this (`#if canImport(Security)`
  for Keychain, `FileKeyStore` fallback for Linux). The TUI layer must hold the same line.
- **Foundation-only is the bar.** AgentCore is Foundation-only and `Sendable` throughout
  (`ChatProvider`, `StreamEvent`, `ChatMessage`, `ModelSettings` all `Sendable`). Adding a heavy
  TUI dependency that doesn't build on Linux, or that drags in non-Foundation Apple frameworks,
  breaks the whole premise.
- **The core contract is a stream.** `ProviderRegistry.stream(...)` returns
  `AsyncThrowingStream<StreamEvent, Error>`. `StreamEvent` is a sum type:
  `.delta(String)`, `.reasoning(String)`, `.toolCall(id,name,argumentsJSON)`,
  `.finish(reason:)`, `.usage(promptTokens:completionTokens:)`. **The TUI's primary job is to
  render this stream live, token-by-token, while staying interruptible.**
- **Stateless, Sendable providers.** Keys/model are passed in per call; nothing is mutable across
  the actor boundary. This makes the concurrency model below clean: the agent turn is a single
  cancellable `Task` consuming the stream; the UI is the consumer.

A new SPM executable target (`Kist`) is added to `Package.swift` depending on `AgentCore`. Kist owns
zero provider logic — it is purely orchestration loop + terminal I/O + an agent tool layer.

---

## 1. Terminal rendering approach

### Options evaluated

| Option | Linux? | Foundation-only? | Streaming fit | Deps / risk | Verdict |
|---|---|---|---|---|---|
| **Hand-rolled ANSI** (raw escape codes + termios) | ✅ native | ✅ (Foundation + Glibc/Darwin termios) | ✅ full control of partial-line redraws | zero external deps | **RECOMMENDED** |
| **ncurses via `Cncurses`** | ✅ | ⚠️ C interop, needs system `libncurses` present | ⚠️ cell-buffer model fights token-streaming/scrollback | system lib + module map; brittle across distros | No |
| **swift-tui** (declarative SwiftUI-like TUI) | partial / immature | ✅ pure Swift | ⚠️ retained/diffed tree, awkward for an append-mostly transcript | young, churny, small ecosystem | No (revisit later) |
| **SwiftCrossUI** (TUI backend) | ✅ but heavy | ✅ pure Swift | ⚠️ GUI-shaped abstraction over a terminal | large dep, overkill for a chat transcript | No |
| **swift-term / Terminal.app emulators** | n/a | — | wrong layer (these *emulate* terminals) | — | No |

### Recommendation: **hand-rolled ANSI + raw-mode `termios`** (zero external dependencies)

Rationale:

1. **It is the only option that is unconditionally Linux-clean and Foundation-only.** ncurses needs
   a system library and a C module map that varies by distro; the Swift TUI libraries are either
   immature (swift-tui) or far heavier than a chat transcript warrants (SwiftCrossUI). ANSI escape
   sequences + POSIX `termios` are available identically on macOS and Linux, reachable from Swift
   via `import Glibc` / `import Darwin` with **no package dependency at all**.
2. **A streaming agent transcript is append-mostly, not a grid.** Claude Code's UX is: a scrolling
   transcript above, a fixed input + status region pinned at the bottom. That is the one layout
   ncurses' full-screen cell model actively makes *harder* (it owns the whole screen and breaks
   native scrollback/copy-paste). Append-to-transcript + redraw-only-the-bottom-region is trivial
   with ANSI and gives users working scrollback for free.
3. **Token streaming wants direct stdout control.** `.delta` chunks are just `print` into the
   transcript region with no newline; a cursor-save/restore dance keeps the input line intact. We
   never need a diffing layout engine for this.
4. **Minimal deps = the project's stated value.** AgentCore deliberately ships Foundation-only;
   Kist should not be the target that breaks `swift build` on a bare Linux box.

A thin internal module (`TermDriver`) wraps the raw bits so the rest of Kist never touches escape
codes directly:

```
TermDriver  (the ONLY file that knows ANSI + termios)
  enterRawMode() / restore()          // termios save+set; restore on exit & on signal
  size() -> (cols, rows)              // TIOCGWINSZ ioctl; refresh on SIGWINCH
  moveCursor(row,col) / saveCursor() / restoreCursor()
  clearLine() / clearToEndOfScreen()
  hideCursor() / showCursor()
  write(_ ansi:)                      // raw passthrough
  styled(_ s, fg:, bold:, dim:)       // SGR helpers (8/256 color, degrade to none if NO_COLOR)
```

Everything above `TermDriver` is plain Swift. If a richer widget set is ever justified, swift-tui
can be reconsidered behind this same seam — but v0/v1 do not need it.

> **Color/encoding hygiene:** honor `NO_COLOR` and `TERM=dumb` (degrade to plain text); assume
> UTF-8 output; gate truecolor/emoji behind capability checks so a headless Linux pipe stays clean.

---

## 2. Input / render loop & concurrency model

The hard part is doing two things at once: **reading keystrokes** (line editor with history, multi-line,
Ctrl-C) while **rendering a live `AsyncThrowingStream<StreamEvent>`** from a running turn — without the
two clobbering each other's cursor position.

### Actors and tasks

```
┌──────────────────────────────────────────────────────────────────────┐
│ main() — sets up signal handlers, enters raw mode, runs the REPL loop  │
└──────────────────────────────────────────────────────────────────────┘
         │ owns
         ▼
   @MainActor Renderer  (single writer to stdout — the serialization point)
         ▲                         ▲
         │ render(event)           │ render(inputState)
         │                         │
   ┌─────┴───────┐          ┌──────┴────────────┐
   │ TurnTask    │          │ InputReader        │
   │ (Task)      │          │ (actor / Task)     │
   │ consumes    │          │ reads stdin bytes, │
   │ StreamEvent │          │ maintains line +   │
   │ from        │          │ history + multiline│
   │ AgentCore   │          │ buffer             │
   └─────────────┘          └────────────────────┘
```

- **`Renderer` is a `@MainActor` (or a dedicated `actor`) and is the SOLE writer to stdout.**
  Every byte to the terminal goes through it. This makes the cursor a single-owner resource and
  eliminates the interleaving race entirely — both the streaming turn and the input editor *ask*
  the Renderer to draw; neither writes directly. This is the core safety property of the design.
- **`InputReader`** runs stdin in raw mode and produces parsed input events: printable chars,
  Enter (submit), Shift+Enter / backslash-newline (insert newline → multi-line), Up/Down (history),
  Ctrl-C (interrupt), Ctrl-D (EOF/quit on empty line), Left/Right/Backspace (line editing). On
  Linux/macOS this is a loop over `read(0, ...)` in raw mode, parsing ANSI input sequences
  (`ESC [ A` = up, etc.). Runs on its own `Task` so it never blocks the turn.
- **`TurnTask`** is created when the user submits a prompt. It calls
  `registry.stream(providerId:model:messages:settings:)` and `for try await event in stream { await renderer.render(event) }`.
  It is a single `Task` so it is **cancellable** (see §4). On `.finish`/`.usage` it appends the
  final assistant message to history and hands control back to the input prompt.

### REPL state machine

```
        ┌─────────┐  submit prompt   ┌───────────┐
        │ IDLE    │ ───────────────► │ RUNNING   │
        │ (editing│                  │ (TurnTask │
        │  input) │ ◄─────────────── │  streams) │
        └─────────┘  finish / cancel └───────────┘
            ▲                              │ Ctrl-C
            │                              ▼
            │                        cancel TurnTask,
            └──────── render "[interrupted]" ◄──────
```

- In **IDLE**, keystrokes drive the line editor. Enter submits → transition to RUNNING.
- In **RUNNING**, the input line is disabled for editing; only **Ctrl-C** is live (it cancels the
  TurnTask). Streamed events flow to the transcript. On `.finish` → back to IDLE.
- **Approval prompts** (shell tool calls, §3) are a sub-state of RUNNING: the TurnTask suspends
  awaiting a `y/n` answer that the InputReader feeds back via a one-shot continuation.

### Why this is race-free

There is exactly one writer (Renderer) and the cursor position is therefore never observed in an
inconsistent state. Streaming deltas redraw the transcript region; after each batch the Renderer
restores the cursor to the pinned input line. `Sendable` `StreamEvent` crosses the Task→actor hop
cleanly (already guaranteed by AgentCore). Backpressure is natural: the stream only advances as fast
as the Renderer drains it.

---

## 3. Live rendering of agent activity (Claude-Code-style)

The screen is split into a scrolling **transcript region** (top, owns native scrollback) and a pinned
**status + input region** (bottom 2–3 rows, redrawn in place). Mapping of `StreamEvent` → UI:

| StreamEvent | Rendering |
|---|---|
| `.delta(text)` | Appended inline to the current assistant turn (no newline between chunks). Word-wrapped to `cols`. This is the live token stream. |
| `.reasoning(text)` | Rendered **dimmed/italic** under a collapsible `▸ thinking` header. Off by default; toggle with a key or `--show-reasoning`. Kept visually distinct so it's never confused with the answer. |
| `.toolCall(id,name,argsJSON)` | Rendered as a boxed action card: `⚙ tool: <name>` + pretty-printed args. **Shell/file-mutating tools trigger an inline approval prompt** before execution (see below). |
| `.finish(reason)` | Closes the turn; status line shows reason if abnormal. |
| `.usage(p,c)` | Folded into the status line: `↑p ↓c tok`. |

### Tool approval (the safety gate)

When a `.toolCall` is a shell command or other side-effecting action, the TurnTask **pauses** and the
Renderer draws an approval prompt; InputReader collects the answer:

```
⚙ shell  $ rm -rf build/ && cmake --build .
   run this command?  [y]es / [n]o / [a]lways for session / [e]dit   ›
```

- `y` runs once; `a` whitelists that tool kind for the session; `n` returns a rejection result to the
  agent (which can re-plan); `e` lets the user edit the command before running. Default = **deny on
  ambiguous input** (fail-safe). A `--yolo`/`--auto-approve` flag exists for trusted/non-interactive
  runs but is **off by default**.

### ASCII mockup (proposed layout)

```
┌─ Kist ───────────────────────────────── deepseek · deepseek-reasoner ─┐
│ › build and run the test suite, fix anything red                       │  ← transcript
│                                                                        │     region
│ ▸ thinking  (dim) the project uses swift build; I'll run tests first…  │     (scrolls,
│                                                                        │      native
│ I'll start by running the test suite to see the current state.         │      scrollback)
│                                                                        │
│ ⚙ shell  $ swift test                                                  │
│    run this command?  [y]es / [n]o / [a]lways / [e]dit  › y            │
│    ✓ 0 passed, 3 failed — XCTAssertEqual in StreamTests.swift:42       │
│                                                                        │
│ Found 3 failures in StreamTests. The mock provider emits .delta twice… │
│ ████ streaming… ▌                                                      │  ← live cursor
├────────────────────────────────────────────────────────────────────────┤
│ ⠋ running · turn 1 · ↑1,204 ↓318 tok · ^C interrupt · ^D quit          │  ← status line
│ › fix the duplicate delta and re-run▌                                   │  ← input line
└────────────────────────────────────────────────────────────────────────┘
```

- **Header:** app + active provider/model (switchable via a `/model` slash command).
- **Status line:** spinner while RUNNING, turn counter, live token usage from `.usage`, key hints.
- **Input line:** the editable prompt. `›` prompt glyph; `▌` cursor. Multi-line prompts grow the
  input region upward and push the status line up.

### Slash commands (in-band control)

`/model`, `/provider`, `/clear`, `/history`, `/reasoning on|off`, `/save`, `/resume`, `/help`, `/quit`
— parsed in IDLE before a prompt is sent to the agent. Keeps config in the terminal, not in flags.

---

## 4. Signal handling

Two distinct behaviors, and getting them right is the difference between "feels native" and "wrecks
your terminal."

### SIGINT (Ctrl-C) — cancel the turn, not the app

- In **RUNNING**: SIGINT **cancels the current `TurnTask`** (Swift structured-concurrency
  cancellation propagates into the `for try await` over the stream; AgentCore's stream terminates,
  the in-flight URLSession request is cancelled). Renderer prints `⏹ interrupted` and returns to IDLE.
  The app keeps running. This is the Claude-Code behavior.
- In **IDLE** with a non-empty input buffer: SIGINT clears the line (discard draft), stay in IDLE.
- In **IDLE** with an empty buffer: SIGINT is a no-op hint (`(^C again or ^D to quit)`); a second
  consecutive Ctrl-C, or Ctrl-D, exits cleanly.

**Implementation note (cross-platform):** signal handlers run in a restricted context. Do **not** do
work in the handler. Use a `DispatchSourceSignal` (available on macOS and swift-corelibs-libdispatch
on Linux) — or a self-pipe / `sigwait` on a dedicated thread as a Foundation-only fallback — to turn
the async signal into a normal event delivered to the main loop, which then calls `turnTask?.cancel()`.
Mask the default SIGINT so the process isn't killed.

### SIGWINCH — terminal resized

Recompute `(cols, rows)` via `TIOCGWINSZ` and re-wrap/redraw the pinned bottom region. Transcript
above is left to native reflow.

### Clean teardown — ALWAYS restore terminal state

This is the most common way a TUI ruins a user's session. Guarantees required:

- `termios` original settings are **saved before raw mode** and restored on every exit path:
  normal quit, `.quit` command, EOF, **and** on SIGINT/SIGTERM/SIGHUP and on a Swift fatal error.
- On restore: re-enable canonical mode + echo, **show the cursor** (we hid it), reset SGR colors
  (`ESC [ 0 m`), move to a fresh line.
- Register restoration in a single `defer` at the top of the run loop **and** in the signal path
  (a signal can bypass `defer`), so a kill -TERM still leaves a usable shell. Install a last-resort
  `atexit`-style restore as belt-and-suspenders.

> **Failure mode to avoid:** raw mode left on after a crash = invisible typing, no echo, broken
> shell. Treat terminal restoration as a release-blocking invariant, not a nicety.

---

## 5. v0 (minimal viable) vs v1 (full)

### v0 — PROTOTYPE: "it streams and it doesn't wreck your terminal"

Goal: prove the loop end-to-end on macOS **and** a Linux box.

- [ ] `Kist` SPM executable target depending on AgentCore; builds on macOS + Linux.
- [ ] `TermDriver`: raw mode enter/restore, size, cursor moves, color with `NO_COLOR` fallback.
- [ ] Single-line input editor: typing, backspace, Left/Right, Enter to submit. (No history yet.)
- [ ] REPL loop: IDLE ↔ RUNNING state machine.
- [ ] Streaming render: `.delta` token-by-token into transcript; `.finish`/`.usage` → status line.
- [ ] Provider selection via env/flag (`--provider deepseek`); key via AgentCore KeyStore
      (Keychain on macOS, env/FileKeyStore on Linux).
- [ ] **SIGINT cancels the turn**, not the app. **Guaranteed terminal restore on all exit paths.**
- [ ] Conversation history kept in memory for the session (multi-turn).
- [ ] `.reasoning` rendered (dim) so reasoning models aren't silent.

**Explicitly deferred from v0:** tool execution/approval, multi-line input, scrollback management,
slash commands, persistence/resume.

### v1 — PILOT-READY: "a real agent terminal"

- [ ] **Tool layer + approval prompts** (`.toolCall` → shell/file tools with y/n/always/edit gate,
      deny-by-default). This is the feature that makes it an *agent*, not a chat.
- [ ] Multi-line input (Shift+Enter / `\` continuation) + line history (Up/Down) + persisted history file.
- [ ] Slash commands: `/model`, `/provider`, `/reasoning`, `/clear`, `/help`, `/quit`.
- [ ] SIGWINCH-aware re-wrap; robust word-wrapping; pinned bottom region with working scrollback.
- [ ] Session **persistence + `/resume`**, reusing the FloatingChatApp `AgentCheckpoint`/`CheckpointStore`
      concepts so a Kist session and the GUI app speak the same saved-state format.
- [ ] `--yolo` non-interactive mode (auto-approve) + pipe-friendly plain output when stdout isn't a TTY.
- [ ] Truecolor/256-color theming behind capability detection; `TERM=dumb` degrade path tested.
- [ ] Cross-platform CI: build + smoke test on macOS and Linux.

---

## 6. Risks & unknowns (cross-platform terminal handling)

1. **`termios` / signal portability is the #1 risk.** `import Glibc` vs `import Darwin`, struct
   layout, and `ioctl(TIOCGWINSZ)` constants differ subtly. Raw-mode + restore must be tested on a
   real Linux box from day one — a macOS-only "it works" is meaningless here. **Mitigation:** isolate
   all of it in `TermDriver` behind `#if os(...)`; smoke-test on Linux in v0.
2. **Signal delivery + Swift concurrency.** Turning an async UNIX signal into a clean
   `turnTask.cancel()` is fiddly. `DispatchSourceSignal` is the clean path but relies on
   swift-corelibs-libdispatch on Linux; a self-pipe fallback must exist. Doing work *inside* a raw
   handler is undefined behavior — easy to get wrong.
3. **Terminal-restore-on-crash.** If a panic/`fatalError` fires in raw mode, `defer` may not run.
   Need an `atexit`/signal-based last-resort restore or users get a broken shell. Release-blocking.
4. **Single-writer discipline must hold.** The race-freedom guarantee depends on *nothing* ever
   `print`-ing directly to stdout (no stray debug prints, no library logging to stdout). Any leak
   corrupts the cursor. Route all logging to stderr or a file.
5. **AsyncThrowingStream cancellation actually cancelling the network call.** Cancelling the
   consuming Task must propagate into AgentCore's provider so the HTTP request stops (not just stop
   reading). Needs verification per provider that the underlying URLSession task is cancelled on
   stream teardown — otherwise Ctrl-C "interrupts" visually but the provider keeps billing.
6. **Wide chars / emoji / wrapping width.** Display width ≠ character count for CJK/emoji/combining
   marks; naive wrapping miscounts and corrupts the pinned region. v0 can assume monospace ASCII;
   v1 needs a width function. `TERM=dumb` and non-TTY stdout (piped) must degrade to plain text.
7. **Keychain vs Linux key path divergence.** Already handled by AgentCore (`KeychainKeyStore` vs
   `FileKeyStore`), but Kist's onboarding/error messages must say the right thing per platform
   ("set OPENAI_API_KEY" on Linux vs "stored in Keychain" on macOS).

---

## Recommendation (one line)

Build Kist as a **zero-dependency, Foundation-only Swift executable using hand-rolled ANSI + termios
raw mode**, with a **single `@MainActor` Renderer as the sole stdout writer**, a cancellable
**`TurnTask`** consuming AgentCore's `AsyncThrowingStream<StreamEvent>`, and a separate **`InputReader`**
— the one true cross-platform path that preserves AgentCore's Linux-clean, dependency-light premise.

**Label:** PROTOTYPE-target (this is a spec). v0 → PROTOTYPE, v1 → PILOT-READY when tool-approval +
cross-platform CI + guaranteed terminal restore are all proven on Linux.
