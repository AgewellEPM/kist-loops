#!/bin/bash
# One continuous bring-up: launch win98 -> login -> DOOM -> symbolic control.
# No idle gaps: the runtime reaps quiet guests (observed twice 2026-09-17),
# so this chain keeps owner actions flowing from launch to loop-end.
set -euo pipefail

QMP="/Users/lukekist/.perslis/qmp/win98/qmp.sock"
CAP="/Users/lukekist/.perslis/retroshell-v1-production-dos-qualified/captures"
LANE="/Volumes/PRO-G40/science-loops/system-one-symbolic"
CYCLES="${1:-100}"
RECORD="${2:-$HOME/Desktop/real-doom98-symbolic-combat.mp4}"

OVERLAY="/Users/lukekist/.perslis/legacy-overlays/win98-v5-runtime.qcow2"
if ! pgrep -f "qemu-system-i386 -name legacy-win98" >/dev/null; then
  echo "[bringup] preflight: repairing any leaked clusters from a dirty close"
  rm -f "$QMP"
  qemu-img check -r leaks "$OVERLAY" >/dev/null 2>&1 || true
  qemu-img check "$OVERLAY" | tail -1
fi

echo "[bringup] launching win98 via ~/bin/legacy (lease owner)"
~/bin/legacy open win98 | tail -8

echo "[bringup] waiting for login dialog (boot ~45s), pressing Enter x3"
sleep 45
for i in 1 2 3; do
  perslis vm key --qmp "$QMP" ret >/dev/null 2>&1 || true
  sleep 9
done

echo "[bringup] desktop settle + write GO.BAT"
sleep 12
perslis vm write --qmp "$QMP" --path 'C:\DOOMS\GO.BAT' \
  --content $'c:\r\ncd \\dooms\r\ndoom\r\n' >/dev/null

echo "[bringup] dos-exec GO.BAT (opens DOS prompt, launches DOOM)"
perslis vm dos-exec --qmp "$QMP" --line 'c:\dooms\go.bat' \
  --capture "$CAP/bringup_doom.png" --settle 12 | tail -2

echo "[bringup] handing off to symbolic control loop ($CYCLES cycles)"
cd "$LANE"
exec .venv/bin/python -m doom_lane.real_doom98 \
  --cycles "$CYCLES" --start-game --live --record "$RECORD"
