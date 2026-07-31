#!/bin/bash -p
set -euo pipefail
umask 077
unset ENV BASH_ENV CDPATH
readonly INSTALL_HOME="/Users/lukekist"
readonly SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
HOME="$INSTALL_HOME"
PATH="$SAFE_PATH"
TMPDIR="/private/tmp"
export HOME PATH TMPDIR

usage() {
  /bin/cat <<'USAGE'
Usage: kist-safe-rebuild [options]

Options:
  --repo PATH          Explicit canonical Kist checkout to promote
  --retries N          Extra source-churn retries after the first attempt (default: 1)
  --skip-service-stop  Do not stop kist_service before rebuilding
  -h, --help           Show this help

Repository selection:
  --repo always wins. Without it, the script accepts only the worktree named by
  the installed, validated deployment manifest. Missing or invalid provenance
  is a hard failure; no checkout-name or sibling-directory fallback is used.
USAGE
}

die() {
  printf 'kist-safe-rebuild: %s\n' "$*" >&2
  exit 1
}

REPO=""
REPO_EXPLICIT=0
RETRIES="${KIST_REBUILD_RETRIES:-1}"
STOP_SERVICE=1
if [[ "${KIST_SKIP_SERVICE_STOP:-0}" == "1" ]]; then
  STOP_SERVICE=0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ "$REPO_EXPLICIT" -eq 0 && $# -ge 2 && -n "$2" ]] \
        || die "--repo requires one path and may be supplied only once"
      REPO="$2"
      REPO_EXPLICIT=1
      shift 2
      ;;
    --retries)
      [[ $# -ge 2 ]] || die "--retries requires a number"
      RETRIES="$2"
      shift 2
      ;;
    --skip-service-stop)
      STOP_SERVICE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

[[ "$RETRIES" =~ ^(0|[1-9][0-9]*)$ ]] || die "--retries must be a canonical non-negative integer"
(( RETRIES <= 10 )) || die "--retries may not exceed 10"

readonly BIN_REBUILD="$INSTALL_HOME/bin/kist-rebuild"
readonly BIN_DASHBOARD="$INSTALL_HOME/bin/kist-dashboard"
readonly BIN_KIST="$INSTALL_HOME/bin/kist"
readonly BIN_SAFE_REBUILD="$INSTALL_HOME/bin/kist-safe-rebuild.sh"
readonly MANIFEST="$INSTALL_HOME/bin/kist-current.manifest"
readonly PYTHON="/usr/bin/python3"

[[ -x "$PYTHON" && ! -L "$PYTHON" ]] || die "trusted system Python is unavailable"
python_clean() {
  /usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" LANG=C LC_ALL=C \
    TMPDIR=/private/tmp PYTHONNOUSERSITE=1 "$PYTHON" -I "$@"
}

python_clean - "$INSTALL_HOME" "$BIN_REBUILD" "$BIN_DASHBOARD" "$BIN_KIST" \
  "$BIN_SAFE_REBUILD" <<'PY' || die "installed command ownership, mode, link count, ACL, or ancestry is untrusted"
import ctypes,errno,os,stat,sys
home,*paths=sys.argv[1:]; uid=os.geteuid()
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
libc=ctypes.CDLL(None,use_errno=True)
libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]
libc.acl_get_fd_np.restype=ctypes.c_void_p
libc.acl_free.argtypes=[ctypes.c_void_p]
def acl(fd):
    ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
    if value: libc.acl_free(value); return True
    if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
    raise SystemExit(1)
for path in paths:
    if not os.path.isabs(path) or os.path.realpath(path)!=path or not path.startswith(home+"/"):
        raise SystemExit(1)
    current="/"; parts=[part for part in path.split("/") if part]
    for index,name in enumerate(parts):
        named=os.lstat(os.path.join(current,name)); leaf=index==len(parts)-1
        if leaf:
            if (not stat.S_ISREG(named.st_mode) or named.st_uid!=uid or named.st_nlink!=1
                    or named.st_mode&0o022 or not named.st_mode&stat.S_IXUSR):
                raise SystemExit(1)
            fd=os.open(os.path.join(current,name),os.O_RDONLY|os.O_NOFOLLOW)
            try:
                if fp(os.fstat(fd))!=fp(named) or acl(fd): raise SystemExit(1)
            finally: os.close(fd)
        else:
            if (not stat.S_ISDIR(named.st_mode) or named.st_mode&0o022
                    or named.st_uid not in {0,uid}):
                raise SystemExit(1)
            fd=os.open(os.path.join(current,name),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try:
                candidate=os.path.join(current,name)
                if fp(os.fstat(fd))!=fp(named) or (candidate!=home and candidate.startswith(home+"/") and acl(fd)):
                    raise SystemExit(1)
            finally: os.close(fd)
        current=os.path.join(current,name)
PY

validate_repo_shape() {
  local candidate="$1" canonical
  [[ "$candidate" = /* && -d "$candidate" ]] || return 1
  canonical="$(cd -P -- "$candidate" 2>/dev/null && pwd)" || return 1
  [[ "$canonical" == "$candidate" ]] || return 1
  [[ -f "$candidate/Package.swift" \
     && -f "$candidate/Sources/Kist/KistRunner.swift" \
     && -f "$candidate/Sources/AgentCore/CaptainOrchestrator.swift" \
     && -f "$candidate/Tests/KistTests/KistOptionsTests.swift" ]] || return 1
  /usr/bin/grep -Fq '.executable(name: "kist"' "$candidate/Package.swift" 2>/dev/null \
    || return 1
  printf '%s\n' "$canonical"
}

manifest_worktree() {
  python_clean - "$MANIFEST" <<'PY'
import os
import hashlib
import stat
import sys

path = sys.argv[1]
uid = os.geteuid()
before = os.lstat(path)
def fp(value):
    return (
        value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_size,
        value.st_nlink, value.st_mtime_ns, value.st_ctime_ns,
    )
identity = fp(before)
if (
    not stat.S_ISREG(before.st_mode)
    or before.st_uid != uid
    or before.st_nlink != 1
    or before.st_mode & 0o022
    or before.st_size > 262144
):
    raise SystemExit(1)
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    if fp(os.fstat(fd)) != identity:
        raise SystemExit(1)
    raw = bytearray()
    while len(raw) < before.st_size:
        block = os.read(fd, min(65536, before.st_size - len(raw)))
        if not block:
            raise SystemExit(1)
        raw.extend(block)
    if os.read(fd, 1):
        raise SystemExit(1)
    after = os.fstat(fd)
    named = os.lstat(path)
    for value in (after, named):
        if fp(value) != identity:
            raise SystemExit(1)
finally:
    os.close(fd)

try:
    text = bytes(raw).decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(1)
if not text.endswith("\n") or "\r" in text:
    raise SystemExit(1)
fields = {}
for line in text.splitlines():
    if not line or ":" not in line:
        raise SystemExit(1)
    key, value = line.split(":", 1)
    key, value = key.strip().lower(), value.strip()
    if not key or not value or key in fields:
        raise SystemExit(1)
    fields[key] = value
if fields.get("schema") not in {"3", "4"}:
    raise SystemExit(1)
root = fields.get("worktree", "")
if (
    not root
    or not os.path.isabs(root)
    or os.path.realpath(root) != root
    or not os.path.isdir(root)
    or any(ord(character) < 32 or ord(character) == 127 for character in root)
):
    raise SystemExit(1)
print("manifest-sha256=" + hashlib.sha256(bytes(raw)).hexdigest())
print("worktree=" + root)
PY
}

EXPECTED_INSTALLED_MANIFEST=""
if [[ "$REPO_EXPLICIT" -eq 1 ]]; then
  REPO="$(validate_repo_shape "$REPO")" \
    || die "--repo is not one canonical Kist checkout"
else
  [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] \
    || die "installed deployment provenance is missing"
  validation="$("$BIN_REBUILD" --validate-deployment 2>/dev/null)" \
    || die "installed deployment provenance did not validate"
  validation_projection="$(python_clean - "$validation" <<'PY'
import re,sys
lines=sys.argv[1].splitlines()
if len(lines) not in {1,2} or not lines[0].startswith("validated deployment: "):
    raise SystemExit(1)
root=lines[0][len("validated deployment: "):]
if not root:
    raise SystemExit(1)
print("worktree="+root)
if len(lines)==2:
    match=re.fullmatch(r"manifest-sha256: ([0-9a-f]{64})",lines[1])
    if not match:
        raise SystemExit(1)
    print("manifest-sha256="+match.group(1))
PY
  )" || die "installed deployment validation returned a malformed identity"
  VALIDATED_REPO="$(printf '%s\n' "$validation_projection" | /usr/bin/awk -F= \
    '$1=="worktree"{if(seen++)exit 2;value=substr($0,10)} END{if(seen!=1||value=="")exit 3;print value}')" \
    || die "installed deployment validation omitted its worktree"
  VALIDATED_MANIFEST="$(printf '%s\n' "$validation_projection" | /usr/bin/awk -F= \
    '$1=="manifest-sha256"{if(seen++)exit 2;value=substr($0,17)} END{if(seen>1)exit 3;print value}')" \
    || die "installed deployment validation returned duplicate manifest identities"
  selection="$(manifest_worktree)" \
    || die "installed deployment manifest is invalid"
  REPO="$(printf '%s\n' "$selection" | /usr/bin/awk -F= \
    '$1=="worktree"{if(seen++)exit 2;value=substr($0,10)} END{if(seen!=1||value=="")exit 3;print value}')" \
    || die "installed deployment manifest omitted its worktree"
  EXPECTED_INSTALLED_MANIFEST="$(printf '%s\n' "$selection" | /usr/bin/awk -F= \
    '$1=="manifest-sha256"{if(seen++)exit 2;value=substr($0,17)} END{if(seen!=1||value!~/^[0-9a-f]{64}$/)exit 3;print value}')" \
    || die "installed deployment manifest omitted its stable identity"
  REPO="$(validate_repo_shape "$REPO")" \
    || die "manifest worktree is not one canonical Kist checkout"
  [[ "$VALIDATED_REPO" == "$REPO" ]] \
    || die "validated deployment does not match the manifest worktree"
  if [[ -n "$VALIDATED_MANIFEST" ]]; then
    [[ "$VALIDATED_MANIFEST" == "$EXPECTED_INSTALLED_MANIFEST" ]] \
      || die "validated deployment changed before safe selection"
  else
    # The previous gate does not know the internal CAS option. Its first bootstrap pass installs
    # the compatibility-aware gate and a transitional v2 manifest; the required second pass uses
    # the lease-bound identity above and promotes the v3 closure.
    EXPECTED_INSTALLED_MANIFEST=""
  fi
fi

if [[ "$STOP_SERVICE" -eq 1 && -f "$INSTALL_HOME/.kist/scripts/kist_service.py" ]]; then
  python_clean "$INSTALL_HOME/.kist/scripts/kist_service.py" stop || true
fi

log() {
  printf '[%s] %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*"
}

attempt=1
max_attempts=$((RETRIES + 1))
LOG_FILES=()
cleanup_logs() {
  if (( ${#LOG_FILES[@]} )); then
    /bin/rm -f -- "${LOG_FILES[@]}"
  fi
}
trap cleanup_logs EXIT
while true; do
  log "Running explicit promotion (attempt ${attempt}/${max_attempts}) in $REPO"
  log_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/kist-safe-rebuild.XXXXXX")" \
    || die "cannot create a private rebuild log"
  /bin/chmod 600 "$log_file"
  LOG_FILES+=("$log_file")
  rebuild_arguments=(--force)
  if [[ -n "$EXPECTED_INSTALLED_MANIFEST" ]]; then
    rebuild_arguments+=(--expect-installed-manifest-sha256 "$EXPECTED_INSTALLED_MANIFEST")
  fi
  if (
    cd "$REPO"
    MYTHOS_REPO="$REPO" "$BIN_REBUILD" "${rebuild_arguments[@]}"
  ) >"$log_file" 2>&1; then
    log "kist-rebuild succeeded on attempt ${attempt}"
    break
  else
    status=$?
  fi

  if (( attempt <= RETRIES )) && {
    /usr/bin/grep -q "source tree changed during the release build" "$log_file" ||
    /usr/bin/grep -q "was modified during the build" "$log_file"
  }; then
    log "Detected source tree churn; retrying (${attempt}/${RETRIES})."
    ((attempt++))
    continue
  fi

  log "kist-rebuild failed. Tail of logs:"
  /usr/bin/tail -n 40 "$log_file"
  exit "$status"
done

log "Validating promoted provenance"
"$BIN_DASHBOARD" --provenance-validate \
  || die "promoted deployment provenance validation failed"

log "Running installed help and version smoke checks"
"$BIN_KIST" --help >/dev/null
version="$("$BIN_KIST" --version)"
[[ "$version" =~ ^kist\ (0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$ ]] \
  || die "installed --version output is not semantic"

log "PASS: kist is ready with validated deployment provenance"
