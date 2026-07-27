#!/bin/bash
# Install the /design-flow slash command into kist, and put the designflow binary
# on PATH. Idempotent. Run from the kist repo root:  bash contrib/kist-commands/install.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# 1. Install every command (kist reads ~/.config/kist/commands/<name>.md).
CMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/kist/commands"
mkdir -p "$CMD_DIR"
for md in "$HERE"/*.md; do
  cp "$md" "$CMD_DIR/"
  echo "installed: $CMD_DIR/$(basename "$md")  →  type /$(basename "$md" .md) in kist"
done

# 2. Build the binary and put it on PATH (~/bin, override with DESIGNFLOW_BIN_DIR).
BIN_DIR="${DESIGNFLOW_BIN_DIR:-$HOME/bin}"
mkdir -p "$BIN_DIR"
( cd "$REPO" && swift build --product designflow )
cp "$REPO/.build/debug/designflow" "$BIN_DIR/designflow"
chmod +x "$BIN_DIR/designflow"
echo "installed: $BIN_DIR/designflow  (ensure $BIN_DIR is on your PATH)"

echo "done. try:  designflow run --once --dry-run"
