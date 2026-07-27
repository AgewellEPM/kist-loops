#!/usr/bin/env bash
# Live end-to-end dogfood of the kist-control desktop broker: real binary + real Unix socket + peer auth +
# BrokerCore gates + RealDesktopActuator. Proves the split-identity IPC architecture works (dev mode).
# Uses READ-ONLY actions (screen_size / mouse_position) so it never moves the cursor or clicks.
# Does NOT verify TCC separation (that needs code-signing + the on-hardware test in dist/kist-control/README.md).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(swift build --product kist-control --show-bin-path 2>/dev/null)/kist-control"
[ -x "$BIN" ] || { echo "FAIL: kist-control not built"; exit 1; }

# ALWAYS clean up any broker we started + its socket, on ANY exit (success, assertion fail, or interrupt) —
# never leave a live dev-trust broker accepting same-uid requests (Codex).
BROKER_PIDS=(); BROKER_SOCKS=()
cleanup() { for p in "${BROKER_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
            for s in "${BROKER_SOCKS[@]:-}"; do [ -n "$s" ] && rm -f "$s" || true; done; }
trap cleanup EXIT INT TERM
fail() { echo "DOGFOOD FAIL: $1"; exit 1; }

LAST_PID=""
start_broker() {  # $1 = socket path, $2.. = extra args ; sets $LAST_PID (runs in PARENT shell, no subshell,
                  # so the cleanup arrays + trap actually see it)
  rm -f "$1"
  "$BIN" --socket "$1" "${@:2}" >/dev/null 2>&1 &
  LAST_PID=$!; disown "$LAST_PID" 2>/dev/null || true
  BROKER_PIDS+=("$LAST_PID"); BROKER_SOCKS+=("$1")   # registered for cleanup BEFORE we can fail
  for _ in $(seq 1 50); do [ -S "$1" ] && break; sleep 0.1; done
  [ -S "$1" ] || fail "broker did not start on $1"
}

# 1) happy path (dev-trust): real read-only actions round-trip OK
SOCK="/tmp/kc_dogfood.$$.sock"
start_broker "$SOCK" --dev-trust-same-uid; PID="$LAST_PID"
OUT="$("$BIN" --send screen_size    --socket "$SOCK" 2>&1 || true)"; echo "$OUT" | grep -q '^OK:' || fail "screen_size: $OUT"
OUT="$("$BIN" --send mouse_position --socket "$SOCK" 2>&1 || true)"; echo "$OUT" | grep -q '^OK:' || fail "mouse_position: $OUT"
kill "$PID" 2>/dev/null || true; rm -f "$SOCK"

# 2) fail-closed: no requirement + no dev-trust ⇒ every peer DENIED (no actuation)
SOCK2="/tmp/kc_deny.$$.sock"
start_broker "$SOCK2"; PID="$LAST_PID"
OUT="$("$BIN" --send screen_size --socket "$SOCK2" 2>&1 || true)"
echo "$OUT" | grep -q '^DENIED\[unauthorizedPeer\]' || fail "deny path did not fail closed: $OUT"
kill "$PID" 2>/dev/null || true; rm -f "$SOCK2"

echo "DOGFOOD OK: happy path round-trips real actions; fail-closed denies unauthenticated peers."
