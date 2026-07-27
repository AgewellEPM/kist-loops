#!/usr/bin/env bash
# Linux OS-sandbox (bubblewrap) enforcement proof.
#
# The Swift unit test (BubblewrapSandboxTests) pins that `BubblewrapSandbox.buildArgs` emits a specific
# bwrap argv for a confined policy. THIS script proves that same argv actually enforces the policy on a
# real Linux kernel: network egress denied + filesystem writes confined to the project root. Together
# they prove the Swift → kernel-enforcement chain without compiling the whole package on Linux.
#
# Runs inside a privileged Ubuntu container so bubblewrap can create user namespaces. Requires Docker.
#   usage: scripts/linux-sandbox-test.sh
set -euo pipefail

IMAGE="ubuntu:22.04"
echo "==> pulling $IMAGE (if needed) and running bubblewrap enforcement checks"

docker run --rm --privileged "$IMAGE" bash -eu -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null && apt-get install -y -qq bubblewrap iproute2 >/dev/null
  ROOT=/work && mkdir -p "$ROOT"
  fail() { echo "FAIL: $1"; exit 1; }

  # --- policy argv, mirroring BubblewrapSandbox.buildArgs(confined) ---
  CONFINE=( --die-with-parent --unshare-pid --new-session --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /run --bind "$ROOT" "$ROOT" --unshare-net --chdir "$ROOT" -- )

  echo "-- check 1: network egress denied (--unshare-net → only loopback) --"
  IFACES=$(bwrap "${CONFINE[@]}" ip -o link show | awk -F": " "{print \$2}" | tr "\n" " ")
  echo "   ifaces in sandbox: [$IFACES]"
  echo "$IFACES" | grep -qw eth0 && fail "eth0 visible inside --unshare-net sandbox (egress not denied)"
  echo "$IFACES" | grep -qw lo   || fail "loopback missing (sandbox broken)"
  # sanity: WITHOUT --unshare-net the host iface IS visible (proves the check is meaningful)
  NOSHARE=( --die-with-parent --ro-bind / / --dev /dev --proc /proc -- )
  bwrap "${NOSHARE[@]}" ip -o link show | grep -qw eth0 || echo "   (note: host has no eth0 to compare; egress check still valid)"
  echo "   OK: no external interface inside the network sandbox"

  echo "-- check 2: writes confined to project root --"
  bwrap "${CONFINE[@]}" sh -c "echo inside > $ROOT/ok.txt" || fail "write INSIDE root was refused"
  echo "   OK: write inside \$ROOT succeeded"
  if bwrap "${CONFINE[@]}" sh -c "echo pwned > /etc/pwned" 2>/dev/null; then
    fail "write OUTSIDE root (/etc) SUCCEEDED — confinement broken"
  fi
  echo "   OK: write to /etc was refused (read-only host)"
  if bwrap "${CONFINE[@]}" sh -c "echo pwned > /usr/pwned" 2>/dev/null; then
    fail "write to /usr SUCCEEDED — confinement broken"
  fi
  echo "   OK: write to /usr was refused"

  echo "-- check 3: host runtime sockets masked (--tmpfs /run) --"
  # Plant a socket-like file at /run and confirm the sandbox sees an EMPTY /run (tmpfs), not the host one.
  echo hostsecret > /run/host_marker
  if bwrap "${CONFINE[@]}" sh -c "cat /run/host_marker" 2>/dev/null | grep -q hostsecret; then
    fail "/run host contents visible inside sandbox — socket dir not masked (docker.sock reachable)"
  fi
  echo "   OK: /run is a fresh tmpfs; host sockets not exposed"

  echo "-- check 4: PID namespace isolated (--unshare-pid) --"
  # Inside a fresh PID ns the sandbox should see very few PIDs (itself as ~pid 1/2), not the host set.
  NPIDS=$(bwrap "${CONFINE[@]}" sh -c "ls -d /proc/[0-9]* 2>/dev/null | wc -l")
  echo "   visible PIDs in sandbox: $NPIDS"
  [ "$NPIDS" -le 5 ] || fail "sandbox sees $NPIDS PIDs — PID namespace not isolated (/proc/<pid>/environ leak)"
  echo "   OK: PID namespace isolated"

  echo "ALL BUBBLEWRAP ENFORCEMENT CHECKS PASSED"
'
echo "==> linux-sandbox-test: PASS"
