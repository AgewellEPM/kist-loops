#!/bin/bash -p
# Canonical authenticated Kist dashboard launcher. Parse first; validate deployment provenance before
# process mutation; replace only an exactly-owned, authenticated Kist listener.
set -euo pipefail
umask 077
unset ENV BASH_ENV CDPATH

readonly INSTALL_HOME="/Users/lukekist"
readonly KIST_HOME="$INSTALL_HOME/.kist"
readonly PYTHON="/usr/bin/python3"
readonly RUNTIME="$KIST_HOME/scripts/kist_runtime.py"
readonly DASHBOARD_LAUNCHER="$INSTALL_HOME/bin/kist-dashboard"
readonly DASHBOARD_REBUILD="$INSTALL_HOME/bin/kist-rebuild"
readonly SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
readonly SERVICE="kist-live-dashboard"
PATH="$SAFE_PATH"
HOME="$INSTALL_HOME"
export HOME PATH

usage() {
  printf '%s\n' 'usage: kist-dashboard [control] [conversation|flow|timeline|fleet|vms|plan] [--project-root PATH] [--port PORT] [--no-open]'
}
die() { printf 'kist-dashboard: %s\n' "$*" >&2; exit 1; }

VIEW=""
PORT=7777
PROJECT_ROOT=""
CONTROL=0
NO_OPEN=0
PROJECT_SEEN=0
PORT_SEEN=0
HELP=0
EVALUATE=0
VALIDATE=0
REQUIRE_ENTERPRISE=0
EVAL_BINARY=""
EVAL_WRAPPER=""
EVAL_DASHBOARD=""
EVAL_REBUILD=""
EVAL_SAFE_REBUILD=""
EVAL_RESOURCE_CODE=""
EVAL_RESOURCE_WEB=""
EVAL_CLOSURE_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    conversation|flow|timeline|fleet|vms|plan)
      [[ -z "$VIEW" ]] || die 'dashboard view may be supplied only once'
      VIEW="$1"; shift ;;
    control)
      [[ "$CONTROL" -eq 0 ]] || die 'control may be supplied only once'
      CONTROL=1; shift ;;
    --project-root)
      [[ "$PROJECT_SEEN" -eq 0 && $# -ge 2 && -n "$2" ]] || die '--project-root requires one value and may be supplied only once'
      PROJECT_SEEN=1; PROJECT_ROOT="$2"; shift 2 ;;
    --project-root=*)
      [[ "$PROJECT_SEEN" -eq 0 && -n "${1#--project-root=}" ]] || die '--project-root requires one value and may be supplied only once'
      PROJECT_SEEN=1; PROJECT_ROOT="${1#--project-root=}"; shift ;;
    --port)
      [[ "$PORT_SEEN" -eq 0 && $# -ge 2 ]] || die '--port requires one value and may be supplied only once'
      PORT_SEEN=1; PORT="$2"; shift 2 ;;
    --port=*)
      [[ "$PORT_SEEN" -eq 0 && -n "${1#--port=}" ]] || die '--port requires one value and may be supplied only once'
      PORT_SEEN=1; PORT="${1#--port=}"; shift ;;
    --no-open)
      [[ "$NO_OPEN" -eq 0 ]] || die '--no-open may be supplied only once'
      NO_OPEN=1; shift ;;
    -h|--help)
      [[ "$HELP" -eq 0 ]] || die '--help may be supplied only once'
      HELP=1; shift ;;
    --provenance-evaluate)
      [[ "$EVALUATE" -eq 0 ]] || die '--provenance-evaluate may be supplied only once'
      [[ $# -eq 3 || $# -eq 5 || $# -eq 6 || $# -eq 8 ]] \
        || die '--provenance-evaluate requires BINARY WRAPPER [DASHBOARD REBUILD [SAFE_REBUILD [RESOURCE_CODE RESOURCE_WEB]]]'
      EVALUATE=1; EVAL_BINARY="$2"; EVAL_WRAPPER="$3"
      if [[ $# -eq 8 ]]; then
        [[ -n "$7" && -n "$8" ]] || die 'both resource paths are required'
        EVAL_DASHBOARD="$4"; EVAL_REBUILD="$5"; EVAL_SAFE_REBUILD="$6"
        EVAL_RESOURCE_CODE="$7"; EVAL_RESOURCE_WEB="$8"
        EVAL_CLOSURE_VERSION=4; shift 8
      elif [[ $# -eq 6 ]]; then
        EVAL_DASHBOARD="$4"; EVAL_REBUILD="$5"; EVAL_SAFE_REBUILD="$6"
        EVAL_CLOSURE_VERSION=3; shift 6
      elif [[ $# -eq 5 ]]; then
        EVAL_DASHBOARD="$4"; EVAL_REBUILD="$5"
        EVAL_CLOSURE_VERSION=2; shift 5
      else
        EVAL_CLOSURE_VERSION=2; shift 3
      fi ;;
    --provenance-validate)
      [[ "$VALIDATE" -eq 0 ]] || die '--provenance-validate may be supplied only once'
      VALIDATE=1; shift ;;
    --require-enterprise)
      [[ "$REQUIRE_ENTERPRISE" -eq 0 ]] || die '--require-enterprise may be supplied only once'
      REQUIRE_ENTERPRISE=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [[ ! "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$PORT > 65535 )); then
  die '--port requires a canonical integer from 1 through 65535'
fi
if [[ "$HELP" -eq 1 ]]; then usage; exit 0; fi
if [[ "$EVALUATE" -eq 1 ]]; then
  [[ -z "$VIEW" && "$CONTROL" -eq 0 && "$NO_OPEN" -eq 0 && "$PROJECT_SEEN" -eq 0 && "$PORT_SEEN" -eq 0 ]] \
    || die '--provenance-evaluate cannot be combined with launch arguments'
  for override in "$EVAL_BINARY" "$EVAL_WRAPPER" "$EVAL_DASHBOARD" "$EVAL_REBUILD" "$EVAL_SAFE_REBUILD"; do
    [[ -z "$override" || "$override" = /* ]] || die 'provenance override paths must be absolute'
  done
fi
if [[ "$VALIDATE" -eq 1 ]]; then
  [[ "$EVALUATE" -eq 0 && -z "$VIEW" && "$CONTROL" -eq 0 && "$NO_OPEN" -eq 0 && "$PROJECT_SEEN" -eq 0 && "$PORT_SEEN" -eq 0 ]] \
    || die '--provenance-validate cannot be combined with launch arguments'
fi
if [[ "$REQUIRE_ENTERPRISE" -eq 1 && "$VALIDATE" -ne 1 ]]; then
  die '--require-enterprise is valid only with --provenance-validate'
fi
[[ -x "$PYTHON" && ! -L "$PYTHON" ]] || die "trusted system python is unavailable at $PYTHON"

python_clean() {
  /usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" LANG=C LC_ALL=C \
    TMPDIR=/private/tmp PYTHONNOUSERSITE=1 "$PYTHON" -I "$@" 8>&- 9>&-
}

# @KIST_RESOURCE_PROTOCOL@

# Hold a kernel-backed shared deployment lease from validation through authenticated readiness.
# Rebuild takes the same file exclusively, so the bytes proven below cannot be replaced between
# validation and execution.  This shell owns the inherited open-file descriptions directly: a
# short trusted Python process applies BSD flock, exits, and leaves the lock with this process.
DEPLOY_LEASE_ACTIVE=0
DEPLOY_LEASE_IDENTITY=""
LAUNCH_LEASE_ACTIVE=0
LAUNCH_LEASE_IDENTITY=""

lease_python() {
  /usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" LANG=C LC_ALL=C \
    TMPDIR=/private/tmp PYTHONNOUSERSITE=1 "$PYTHON" -I "$@"
}

prepare_lease_path() {
  python_clean - "$1" <<'PY'
import os,stat,sys
path=sys.argv[1]; uid=os.geteuid()
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
def dfp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid)
parent=os.path.dirname(path); leaf=os.path.basename(path)
if not leaf or "/" in leaf or not path.startswith("/") or os.path.realpath(parent)!=parent:
    raise SystemExit(1)
directory=os.open("/",os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW); pins=[]
try:
    root=os.fstat(directory)
    if not stat.S_ISDIR(root.st_mode) or root.st_uid not in {0,uid} or root.st_mode&0o022:
        raise SystemExit(1)
    for part in [item for item in parent.split("/") if item]:
        named=os.stat(part,dir_fd=directory,follow_symlinks=False)
        if (not stat.S_ISDIR(named.st_mode) or named.st_uid not in {0,uid}
                or named.st_mode&0o022):
            raise SystemExit(1)
        child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=directory)
        if fp(os.fstat(child))!=fp(named):
            os.close(child); raise SystemExit(1)
        pins.append((directory,part,child,dfp(named))); directory=child
    try:
        named=os.stat(leaf,dir_fd=directory,follow_symlinks=False)
    except FileNotFoundError:
        fd=os.open(leaf,os.O_RDONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,
                   dir_fd=directory)
        os.close(fd); os.fsync(directory)
        named=os.stat(leaf,dir_fd=directory,follow_symlinks=False)
    if (not stat.S_ISREG(named.st_mode) or named.st_uid!=uid or named.st_nlink!=1
            or stat.S_IMODE(named.st_mode)!=0o600):
        raise SystemExit(1)
    fd=os.open(leaf,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=directory)
    try:
        if fp(os.fstat(fd))!=fp(named):
            raise SystemExit(1)
    finally:
        os.close(fd)
    for parent_fd,name,child_fd,identity in pins:
        if dfp(os.fstat(child_fd))!=identity:
            raise SystemExit(1)
        if dfp(os.stat(name,dir_fd=parent_fd,follow_symlinks=False))!=identity:
            raise SystemExit(1)
finally:
    descriptors={directory}
    for parent_fd,_,child_fd,_ in pins:
        descriptors.update({parent_fd,child_fd})
    for descriptor in descriptors:
        os.close(descriptor)
PY
}

lease_fd_operation() {
  local action="$1" mode="$2" path="$3" fd="$4" expected="${5-}"
  lease_python - "$action" "$mode" "$path" "$fd" "$expected" <<'PY'
import fcntl,os,stat,sys,time
action,mode,path,fd_text,expected=sys.argv[1:]; uid=os.geteuid(); fd=int(fd_text)
other=8 if fd==9 else 9
try: os.close(other)
except OSError: pass
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
def dfp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid)
def lock_fp(value): return (value.st_dev,value.st_ino)
def valid_file(value):
    return (stat.S_ISREG(value.st_mode) and value.st_uid==uid and value.st_nlink==1
            and stat.S_IMODE(value.st_mode)==0o600)
parent=os.path.dirname(path); leaf=os.path.basename(path)
if action not in {"acquire","assert"} or mode not in {"shared","exclusive"} or fd not in {8,9}:
    raise SystemExit(1)
if not leaf or "/" in leaf or not path.startswith("/") or os.path.realpath(parent)!=parent:
    raise SystemExit(1)
inherited=os.fstat(fd)
if not valid_file(inherited):
    raise SystemExit(1)
directory=os.open("/",os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW); pins=[]
try:
    root=os.fstat(directory)
    if not stat.S_ISDIR(root.st_mode) or root.st_uid not in {0,uid} or root.st_mode&0o022:
        raise SystemExit(1)
    for part in [item for item in parent.split("/") if item]:
        named=os.stat(part,dir_fd=directory,follow_symlinks=False)
        if (not stat.S_ISDIR(named.st_mode) or named.st_uid not in {0,uid}
                or named.st_mode&0o022):
            raise SystemExit(1)
        child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=directory)
        if fp(os.fstat(child))!=fp(named):
            os.close(child); raise SystemExit(1)
        pins.append((directory,part,child,dfp(named))); directory=child
    named=os.stat(leaf,dir_fd=directory,follow_symlinks=False)
    named_fd=os.open(leaf,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=directory)
    try:
        if not valid_file(named) or fp(os.fstat(named_fd))!=fp(named):
            raise SystemExit(1)
        if lock_fp(named)!=lock_fp(inherited) or fp(os.fstat(fd))!=fp(inherited):
            raise SystemExit(1)
        identity=f"{inherited.st_dev}:{inherited.st_ino}"
        if action=="assert":
            if identity!=expected:
                raise SystemExit(1)
        else:
            deadline=time.monotonic()+30.0
            operation=(fcntl.LOCK_SH if mode=="shared" else fcntl.LOCK_EX)|fcntl.LOCK_NB
            while True:
                try:
                    fcntl.flock(fd,operation); break
                except BlockingIOError:
                    if time.monotonic()>=deadline:
                        raise SystemExit(75)
                    time.sleep(.05)
        if fp(os.fstat(fd))!=fp(inherited):
            raise SystemExit(1)
        refreshed=os.stat(leaf,dir_fd=directory,follow_symlinks=False)
        if fp(refreshed)!=fp(named) or lock_fp(refreshed)!=lock_fp(inherited):
            raise SystemExit(1)
        for parent_fd,name,child_fd,pinned in pins:
            if dfp(os.fstat(child_fd))!=pinned:
                raise SystemExit(1)
            if dfp(os.stat(name,dir_fd=parent_fd,follow_symlinks=False))!=pinned:
                raise SystemExit(1)
        print(identity)
    finally:
        os.close(named_fd)
finally:
    descriptors={directory}
    for parent_fd,_,child_fd,_ in pins:
        descriptors.update({parent_fd,child_fd})
    for descriptor in descriptors:
        os.close(descriptor)
PY
}

assert_lease() {
  local slot="$1"
  if [[ "$slot" == deployment ]]; then
    if [[ "$DEPLOY_LEASE_ACTIVE" -ne 1 ]] \
       || ! lease_fd_operation assert shared "$INSTALL_HOME/bin/.kist-deployment.lock" 9 \
            "$DEPLOY_LEASE_IDENTITY" >/dev/null; then
      die 'deployment lease descriptor is not held by this process'
    fi
  else
    if [[ "$LAUNCH_LEASE_ACTIVE" -ne 1 ]] \
       || ! lease_fd_operation assert exclusive "$RUN_DIR/dashboard-$PORT.launch.lock" 8 \
            "$LAUNCH_LEASE_IDENTITY" >/dev/null; then
      die 'launch lease descriptor is not held by this process'
    fi
  fi
}
start_lease() {
  local slot="$1" mode="$2" lock_path="$3" identity=""
  [[ "$mode" == shared || "$mode" == exclusive ]] || die "invalid $slot lease mode"
  prepare_lease_path "$lock_path" || die "$slot lease path is unsafe"
  if [[ "$slot" == deployment ]]; then
    [[ "$DEPLOY_LEASE_ACTIVE" -eq 0 ]] || die 'deployment lease is already active'
    exec 9< "$lock_path"
    identity=$(lease_fd_operation acquire "$mode" "$lock_path" 9) \
      || { exec 9>&-; die "timed out or failed to acquire the $slot $mode lease"; }
    [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] \
      || { exec 9>&-; die "$slot lease returned an invalid identity"; }
    DEPLOY_LEASE_IDENTITY="$identity"; DEPLOY_LEASE_ACTIVE=1
  else
    [[ "$LAUNCH_LEASE_ACTIVE" -eq 0 ]] || die 'launch lease is already active'
    exec 8< "$lock_path"
    identity=$(lease_fd_operation acquire "$mode" "$lock_path" 8) \
      || { exec 8>&-; die "timed out or failed to acquire the $slot $mode lease"; }
    [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] \
      || { exec 8>&-; die "$slot lease returned an invalid identity"; }
    LAUNCH_LEASE_IDENTITY="$identity"; LAUNCH_LEASE_ACTIVE=1
  fi
  assert_lease "$slot"
}
release_lease() {
  local slot="$1" status=0
  if [[ "$slot" == deployment ]]; then
    [[ "$DEPLOY_LEASE_ACTIVE" -eq 1 ]] || return 0
    lease_fd_operation assert shared "$INSTALL_HOME/bin/.kist-deployment.lock" 9 \
      "$DEPLOY_LEASE_IDENTITY" >/dev/null || status=1
    exec 9>&-
    DEPLOY_LEASE_ACTIVE=0; DEPLOY_LEASE_IDENTITY=""
  else
    [[ "$LAUNCH_LEASE_ACTIVE" -eq 1 ]] || return 0
    lease_fd_operation assert exclusive "$RUN_DIR/dashboard-$PORT.launch.lock" 8 \
      "$LAUNCH_LEASE_IDENTITY" >/dev/null || status=1
    exec 8>&-
    LAUNCH_LEASE_ACTIVE=0; LAUNCH_LEASE_IDENTITY=""
  fi
  return "$status"
}
# shellcheck disable=SC2329 # Invoked by EXIT/INT/TERM traps below.
release_all_leases() {
  local status=0
  release_lease launch || status=1
  release_lease deployment || status=1
  return "$status"
}
trap release_all_leases EXIT

if [[ "$EVALUATE" -eq 0 ]]; then
  start_lease deployment shared "$INSTALL_HOME/bin/.kist-deployment.lock"
fi

[[ -n "$PROJECT_ROOT" ]] || PROJECT_ROOT="$PWD"
[[ -d "$PROJECT_ROOT" ]] || die "dashboard project root is not a directory: $PROJECT_ROOT"
PROJECT_ROOT="$(cd -P -- "$PROJECT_ROOT" && pwd)"
