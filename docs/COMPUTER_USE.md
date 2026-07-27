# Computer Use — driving a native GUI

kist can operate a native macOS app (menus, games, arbitrary UI), not just launch it. This is the
perceive → decide → act → wait loop, built from small composable tools. It is **PROTOTYPE**: the
actuator and perception are real and council-hardened; how *well* it plays a given app is emergent from
the decision model.

## The tools

| Tool | Role | Notes |
|------|------|-------|
| `computer_use_check` | **Readiness** — is everything set up? | Read-only; call this first |
| `computer_control` | **Launch** an app / open a URL | Existing; `open_app` |
| `ui_elements` | **Ground** — read real controls (role, label, exact bounds) from the Accessibility tree | Deterministic; prefer over `locate` for standard apps |
| `ax_press` | **Act by identity** — press a control by label (can't miss) | Most reliable; standard apps |
| `look` | **See** — "what's on screen?" (Moondream caption/query) | Cheap; use before deciding |
| `desktop_control` action=`screenshot` | Capture the screen to a PNG | For `view_image` or `locate` |
| `locate` | **Aim** — pixel coordinates of a named target (vision) | Fallback for games with no AX tree |
| `tap` | **Tight loop** — capture+locate+click in one call | Fastest vision-based per-move |
| `desktop_control` | **Act** — move/click/drag/scroll/type/key; `display` targets any monitor | Raw input; `key` does chords |
| `wait_for_screen` | **Sync** — block until X appears | For loading screens / transitions |
| `watch_screen` | **Watch** — always-on background perception (start/state/stop) | Poll while doing other work |

Coordinates are **screenshot pixels** on the target display — `desktop_control`, `ui_elements`, and `ax_press` take a `display` index (default main). When `ui_elements(display:N)` returns a center, pass the same `display:N` to `desktop_control`.

## The loop the model runs

```
computer_use_check                 # ensure ready; if not, it tells you what to enable
computer_control open_app Fallout  # launch
wait_for_screen "the main menu"    # sync past the intro/loading
ui_elements                        # GROUND: read the real controls (empty → game has no AX tree)
ax_press "New Game"                # act by identity (or: tap "New Game" for a vision-rendered game)
wait_for_screen "character creation"   # VERIFY the transition before the next step
look "whose turn is it?"           # cheap state read to decide the next move
desktop_control key "return"       # raw input when there's no click target
... repeat: ui_elements/look → ax_press/tap/desktop_control → wait_for_screen ...
```

Grounding-first: `ui_elements` + `ax_press` (deterministic, standard apps) → fall back to `look`/`locate`/`tap` (vision) for custom-rendered games. Verify every action with `wait_for_screen`.

`look`/`locate`/`tap`/`wait_for_screen` are gated on a Moondream backend; `desktop_control` needs macOS
Accessibility + Screen Recording. All are approval-gated by default and dropped from the autonomous
coding loop; under `--auto` they run unattended.

## Setup (the part only you can do)

Three things live outside the code. `computer_use_check` reports exactly which are missing.

1. **Accessibility** (mouse/keyboard injection): System Settings → Privacy & Security → Accessibility →
   add & enable the kist binary/terminal.
2. **Screen Recording** (capture): System Settings → Privacy & Security → Screen Recording → same.
3. **Moondream** (the fast vision backend), either:
   - Cloud: `export MOONDREAM_API_KEY=…`
   - Local: run a Moondream server and `export MOONDREAM_BASE_URL=http://localhost:2020/v1`

## Run it

```sh
# verify first — prints a checklist if anything is missing
cu "run computer_use_check and tell me if desktop control is ready"

# a live attempt (unattended). Put the game on your main display, or pass display=N consistently.
cu --auto "Open Fallout. Wait for the main menu, then click New Game, then wait for the
           character screen. Describe what you see at each step."
```

## Honest limits

- **Multi-display:** `desktop_control`, `ui_elements`, and `ax_press` target monitors via the `display` index — run `screen_size` to see what's attached. Use the same display index across grounding (`ui_elements`/`ax_press`), screenshots, and clicks.
- **Turn-based / non-twitch.** Each move is a model round-trip (seconds). Great for Fallout 1/2 and
  menu-driven apps; not for real-time action.
- **Skill is emergent.** The tools won't miss the pixel (`locate` + bounds-checking see to that), but
  whether the model plays *well* is the decision model's competence, not the actuator's.
- **Fire-and-forget input.** `CGEvent.post` can't prove the app consumed a click; `wait_for_screen`
  is how you confirm an action landed.
