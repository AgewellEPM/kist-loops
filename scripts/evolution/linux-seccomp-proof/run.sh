#!/usr/bin/env bash
# Reproducible Linux proof for EvolutionSeccompFilter.
#
# Compiles the EXACT shipped Sources/AgentCore/EvolutionSeccompFilter.swift with main.swift and installs
# the real compiled filter via prctl(PR_SET_SECCOMP), then adversarially attempts the escape syscalls it
# must block (link/symlink/unshare) plus a no-filter control and an allowed-syscall check. Requires Linux
# with a Swift toolchain; unprivileged is fine (the filter installs under PR_SET_NO_NEW_PRIVS). Example
# inside a Linux VM:
#
#   docker run --rm -v "$REPO":/work -w /work swift:6.1 scripts/evolution/linux-seccomp-proof/run.sh
#
# Exits non-zero on any failed check; prints "ALL SECCOMP PROOFS OK" on success.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
out="$(mktemp -d)/seccomp-proof"

swiftc -O \
  "$repo/Sources/AgentCore/EvolutionSeccompFilter.swift" \
  "$here/main.swift" \
  -o "$out"

"$out"
