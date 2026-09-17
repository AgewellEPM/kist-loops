#!/usr/bin/env bash
# Reproducible Linux keystone proof: one command run under BOTH evolution containment layers together —
# the delegated cgroup-v2 supervisor executing bubblewrap, which installs the seccomp escape-deny filter.
#
# Compiles the EXACT shipped sources (HardProcessContainment.swift, LinuxDelegatedCgroupSupervisor.swift,
# EvolutionSeccompFilter.swift) with main.swift. Requires a real cgroup2 host, bubblewrap, and privilege
# to create a delegated subtree. Example inside a Linux VM:
#
#   docker run --rm --privileged --cgroupns=host -v "$REPO":/work -w /work swift:6.1 \
#     bash -c 'apt-get update -qq && apt-get install -y -qq bubblewrap && \
#              scripts/evolution/linux-combined-proof/run.sh'
#
# Proves seccomp denies the candidate hardlink, cgroup.kill reaps a setsid daemon, and the receipt
# validates through HardProcessContainmentContract. Exits non-zero on any failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
out="$(mktemp -d)/combined-proof"

swiftc -O \
  "$repo/Sources/AgentCore/HardProcessContainment.swift" \
  "$repo/Sources/AgentCore/LinuxDelegatedCgroupSupervisor.swift" \
  "$repo/Sources/AgentCore/EvolutionSeccompFilter.swift" \
  "$here/main.swift" \
  -o "$out"

"$out"
