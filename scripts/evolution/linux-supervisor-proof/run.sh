#!/usr/bin/env bash
# Reproducible Linux proof for LinuxDelegatedCgroupSupervisor.
#
# Compiles the EXACT shipped sources (Sources/AgentCore/HardProcessContainment.swift +
# Sources/AgentCore/LinuxDelegatedCgroupSupervisor.swift) together with main.swift and runs the
# adversary/validation suite against a real cgroup-v2 hierarchy. Requires a Linux host with cgroup2 and
# a Swift toolchain, run with enough privilege to create a delegated subtree (root, or a delegated
# systemd scope). A convenient way on macOS is a privileged container inside a Linux VM:
#
#   docker run --rm --privileged --cgroupns=host -v "$REPO":/work -w /work swift:6.1 \
#     scripts/evolution/linux-supervisor-proof/run.sh
#
# Exits non-zero on any failed proof; prints "ALL PROOFS OK" on success.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
out="$(mktemp -d)/supervisor-proof"

swiftc -O \
  "$repo/Sources/AgentCore/HardProcessContainment.swift" \
  "$repo/Sources/AgentCore/LinuxDelegatedCgroupSupervisor.swift" \
  "$here/main.swift" \
  -o "$out"

"$out"
