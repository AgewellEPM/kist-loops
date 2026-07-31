#!/bin/zsh
# Stamp KistBuild.swift with the real git SHA + build date so `kist`'s header shows exactly what's live.
# Run right before a release build/deploy. Idempotent — safe to re-run.
set -eu
here="${0:A:h}"
repo="${here:h}"
f="$repo/Sources/Kist/UX/KistBuild.swift"
[[ -f "$f" ]] || { print -u2 "stamp-build: $f not found"; exit 1 }
sha=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unstamped)
day=$(date +%Y-%m-%d)
/usr/bin/sed -i '' -E "s/static let commit = \"[^\"]*\"/static let commit = \"$sha\"/" "$f"
/usr/bin/sed -i '' -E "s/static let built = \"[^\"]*\"/static let built = \"$day\"/" "$f"
print "stamped KistBuild.swift -> commit=$sha built=$day"
