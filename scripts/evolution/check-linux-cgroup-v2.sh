#!/usr/bin/env bash
set -euo pipefail

# Preflight only: this script never creates, modifies, or deletes a cgroup. It validates the
# operator-provided delegated subtree that a future EvolutionPairedBenchmarkBackend may use.
# A passing preflight is necessary, not sufficient: the trusted executor must still establish
# membership before exec, apply limits, issue a host-owned receipt, and verify cleanup.

usage() {
  printf 'usage: %s <delegated-cgroup-v2-directory>\n' "$0" >&2
  exit 64
}

root=${1-}
[ -n "$root" ] || usage

case "$root" in
  /*) ;;
  *) printf 'cgroup preflight: path must be absolute\n' >&2; exit 2 ;;
esac

[ -d "$root" ] || { printf 'cgroup preflight: not a directory: %s\n' "$root" >&2; exit 2; }
[ -r "$root/cgroup.controllers" ] || { printf 'cgroup preflight: cgroup.controllers is unreadable\n' >&2; exit 2; }
[ -w "$root/cgroup.procs" ] || { printf 'cgroup preflight: cgroup.procs is not writable\n' >&2; exit 2; }
[ -w "$root/cgroup.subtree_control" ] || { printf 'cgroup preflight: cgroup.subtree_control is not writable\n' >&2; exit 2; }
[ -w "$root/cgroup.kill" ] || { printf 'cgroup preflight: cgroup.kill is not writable\n' >&2; exit 2; }

controllers=$(tr '\n' ' ' < "$root/cgroup.controllers")
for controller in cpu memory pids; do
  case " $controllers " in
    *" $controller "*) ;;
    *) printf 'cgroup preflight: required controller unavailable: %s\n' "$controller" >&2; exit 2 ;;
  esac
done

for file in cpu.max memory.max pids.max; do
  [ -w "$root/$file" ] || { printf 'cgroup preflight: limit file is not writable: %s\n' "$file" >&2; exit 2; }
done

printf 'linux delegated cgroup-v2 preflight passed: %s\n' "$root"
