git_repo() {
  python_clean - "$GIT" "$REPO" "$@" <<'PY'
import os,selectors,signal,subprocess,sys,time
git,root,*arguments=sys.argv[1:]
env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":"/var/empty","LANG":"C","LC_ALL":"C","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":"/dev/null","GIT_OPTIONAL_LOCKS":"0","GIT_TERMINAL_PROMPT":"0"}
command=[git,"-C",root,"--no-pager","-c","core.hooksPath=/dev/null","-c","core.fsmonitor=false","-c","core.untrackedCache=false","-c","credential.helper=","-c","maintenance.auto=false",*arguments]
p=subprocess.Popen(command,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
s=selectors.DefaultSelector();s.register(p.stdout,selectors.EVENT_READ,0);s.register(p.stderr,selectors.EVENT_READ,1);buf=[bytearray(),bytearray()];deadline=time.monotonic()+20
try:
    while s.get_map():
        if time.monotonic()>deadline: raise TimeoutError()
        for key,_ in s.select(.1):
            block=os.read(key.fileobj.fileno(),65536)
            if not block:s.unregister(key.fileobj);continue
            buf[key.data]+=block
            if len(buf[key.data])>2*1024*1024:raise OverflowError()
    code=p.wait(timeout=max(.1,deadline-time.monotonic()))
except Exception:
    try:os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=1)
    except Exception:
        try:os.killpg(p.pid,signal.SIGKILL)
        except ProcessLookupError:pass
    raise SystemExit(124)
os.write(1,buf[0]);os.write(2,buf[1]);raise SystemExit(code)
PY
}

# Preserve the existing anti-regression promotion gate. Offline freshness is advisory; identity and
# artifact provenance remain fail-closed regardless of network availability.
if [ "$FORCE" -eq 0 ] && git_repo rev-parse --git-dir >/dev/null 2>&1; then
  if git_repo fetch origin --quiet 2>/dev/null; then
    if git_repo rev-parse --verify origin/main >/dev/null 2>&1 \
       && ! git_repo merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
      behind=$(git_repo rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
      die "refusing to install: $REPO is behind origin/main by ${behind} commit(s); update it or use --force"
    fi
  else
    echo "kist-rebuild · offline; skipping the remote freshness check"
  fi
fi

validate_installed_dashboard || die "dashboard launcher/runtime ownership, mode, or ancestry is untrusted"

BUILD_COMMIT=$(git_repo rev-parse HEAD) || die "cannot read the pre-build Git commit"
SOURCE_SNAPSHOT=$(/usr/bin/mktemp -d "$SNAPSHOT_PARENT/kist-source-snapshot.XXXXXX") \
  || die "cannot create a private source snapshot"
/bin/chmod -N "$SOURCE_SNAPSHOT" 2>/dev/null || true
/bin/chmod 700 "$SOURCE_SNAPSHOT"
snapshot_phase_cleanup() {
  snapshot_status=$?
  trap - 0 1 2 15
  cd "$INSTALL_HOME" 2>/dev/null || snapshot_status=1
  remove_source_snapshot "$SOURCE_SNAPSHOT" || snapshot_status=1
  SOURCE_SNAPSHOT=
  release_deployment_lease || snapshot_status=1
  exit "$snapshot_status"
}
trap snapshot_phase_cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15
BUILD_SOURCE_STATE=$(snapshot_source "$REPO" "$SOURCE_SNAPSHOT") \
  || die "cannot create and hash the private source snapshot"
BUILD_ROOT=$SOURCE_SNAPSHOT
[ -f "$BUILD_ROOT/scripts/kist-dashboard" ] && [ ! -L "$BUILD_ROOT/scripts/kist-dashboard" ] \
  || die "tracked canonical dashboard source is missing"
[ -f "$BUILD_ROOT/scripts/kist-rebuild" ] && [ ! -L "$BUILD_ROOT/scripts/kist-rebuild" ] \
  || die "tracked canonical rebuild source is missing"
[ -f "$BUILD_ROOT/scripts/kist-wrapper" ] && [ ! -L "$BUILD_ROOT/scripts/kist-wrapper" ] \
  || die "tracked canonical wrapper source is missing"
[ -f "$BUILD_ROOT/scripts/kist-safe-rebuild.sh" ] && [ ! -L "$BUILD_ROOT/scripts/kist-safe-rebuild.sh" ] \
  || die "tracked canonical safe-rebuild source is missing"
if [ "${KIST_REBUILD_TESTING-}" = 1 ] && [ -n "${KIST_REBUILD_TEST_AFTER_SNAPSHOT_HOOK-}" ]; then
  [ "$INSTALL_HOME" != /Users/lukekist ] || die "source snapshot test hooks are forbidden for production"
  case "$KIST_REBUILD_TEST_AFTER_SNAPSHOT_HOOK" in /*) ;; *) die "source snapshot test hook must be absolute" ;; esac
  [ -x "$KIST_REBUILD_TEST_AFTER_SNAPSHOT_HOOK" ] && [ ! -L "$KIST_REBUILD_TEST_AFTER_SNAPSHOT_HOOK" ] \
    || die "source snapshot test hook is not one executable regular file"
  /usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" LANG=C LC_ALL=C \
    "$KIST_REBUILD_TEST_AFTER_SNAPSHOT_HOOK" "$REPO" "$BUILD_ROOT" 9>&- \
    || die "source snapshot test hook failed"
fi
# Promotion requires more than a --help smoke: a green suite is the default gate. A dirty tree is
# recorded honestly in the manifest either way; --skip-suite exists for prod-down emergencies only
# and is stamped into test-evidence so a smoke-only deploy can never masquerade as a tested one.
# The evidence string is built causally: the suite portion is recorded only after the suite
# actually passes here, and the smoke portion is APPENDED later (after the release smokes pass),
# so the manifest can never claim a check that has not yet run.
if [ "$SKIP_SUITE" -eq 0 ]; then
  echo "kist-rebuild · running the full test suite before promotion (--skip-suite to bypass) ..."
  # Build the test bundle first, then run it with --skip-build. A COLD `swift test` on this
  # package mis-discovers as "0 tests in 0 suites" (a false green the promotion gate rightly
  # refused); building the bundle explicitly and running the built binary runs the real ~7.4k
  # XCTests. We also require the runner to REPORT that it executed tests: a run that executed
  # zero tests is treated as a discovery failure, never a pass.
  # Package.resolved is part of the hashed source snapshot. Do not refresh remote
  # dependency refs while building that immutable snapshot: doing so makes a valid,
  # locally cached promotion depend on transient GitHub availability.
  ( cd "$BUILD_ROOT" && swift_clean build --scratch-path "$BUILD_ROOT/.build" \
      --disable-automatic-resolution --skip-update --build-tests ) \
    || die "test build failed; refusing to promote an unverified binary"
  SUITE_LOG=$(/usr/bin/mktemp "$SNAPSHOT_PARENT/kist-rebuild-suite.XXXXXX")
  # Force the XCTest bundle (our ~7.5k tests) and DISABLE the swift-testing runner. Mixing the two
  # is racy on this package: swift-testing has zero @Test cases here, so a bare `swift test` can exit
  # reporting "0 tests in 0 suites" without ever running XCTest — a false green the gate then refuses.
  # POSIX-safe: this script is /bin/sh (no PIPESTATUS/bashisms). Capture the suite's REAL exit via
  # `if !` around the subshell (not a `| tee`, whose exit would be tee's), then echo the log for the
  # operator. `set -e` does not abort inside the `if` condition, so a failure is handled here.
  if ( cd "$BUILD_ROOT" && swift_clean test --scratch-path "$BUILD_ROOT/.build" \
       --disable-automatic-resolution --skip-update \
       --skip-build --disable-swift-testing --enable-xctest > "$SUITE_LOG" 2>&1 ); then
    /bin/cat "$SUITE_LOG"
  else
    /bin/cat "$SUITE_LOG"
    /bin/rm -f "$SUITE_LOG"
    die "test suite failed; refusing to promote an unverified binary"
  fi
  /usr/bin/grep -Eq "Executed [1-9][0-9]* test" "$SUITE_LOG" \
    || { /bin/rm -f "$SUITE_LOG"; die "test run executed zero tests (discovery failure); refusing to promote an unverified binary"; }
  /bin/rm -f "$SUITE_LOG"
  TEST_EVIDENCE="suite:pass"
else
  echo "kist-rebuild · WARNING: suite skipped; promoting on smoke evidence only" >&2
  TEST_EVIDENCE="suite:skipped"
fi

echo "kist-rebuild · building release from $REPO ..."
( cd "$BUILD_ROOT" && swift_clean build --scratch-path "$BUILD_ROOT/.build" \
    --disable-automatic-resolution --skip-update -c release ) \
  || die "release build failed"
BIN="$BUILD_ROOT/.build/release/kist"
[ -x "$BIN" ] || die "build produced no runnable binary at $BIN"
AFTER_BUILD_SOURCE_STATE=$(source_state "$BUILD_ROOT") || die "cannot hash the post-build source snapshot"
[ "$BUILD_SOURCE_STATE" = "$AFTER_BUILD_SOURCE_STATE" ] \
  || die "private source snapshot changed during the release build; refusing to promote"

require_deployment_lease exclusive
/bin/mkdir -p "$INSTALL_HOME/bin"
TMP_BINARY=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-current.new.XXXXXX")
TMP_WRAPPER=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist.wrapper.XXXXXX")
TMP_DASHBOARD=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-dashboard.XXXXXX")
TMP_REBUILD=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-rebuild.XXXXXX")
TMP_SAFE_REBUILD=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-safe-rebuild.XXXXXX")
TMP_RESOURCE_CODE=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-resource-code.XXXXXX")
TMP_RESOURCE_WEB=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-resource-web.XXXXXX")
TMP_MANIFEST=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-current.manifest.XXXXXX")
TMP_STAMP=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-build.XXXXXX")
TMP_EVIDENCE=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-current.provenance.XXXXXX")
TMP_STATUS=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-status.XXXXXX")
TMP_NOTARY_ARCHIVE=
TMP_NOTARY_RESULT=
/bin/chmod -N "$TMP_BINARY" "$TMP_WRAPPER" "$TMP_DASHBOARD" "$TMP_REBUILD" "$TMP_SAFE_REBUILD" \
  "$TMP_MANIFEST" "$TMP_STAMP" "$TMP_EVIDENCE" "$TMP_STATUS" \
  "$TMP_RESOURCE_CODE" "$TMP_RESOURCE_WEB" 2>/dev/null || true
cleanup() {
  cleanup_status=$?
  trap - 0 1 2 15
  if [ "$TRANSACTION_ACTIVE" -eq 1 ]; then
    if ensure_exclusive_recovery_lease; then
      transaction_control rollback || cleanup_status=1
    else
      cleanup_status=1
    fi
    TRANSACTION_ACTIVE=0
  fi
  /bin/rm -f "$TMP_BINARY" "$TMP_WRAPPER" "$TMP_DASHBOARD" "$TMP_REBUILD" "$TMP_SAFE_REBUILD" \
    "$TMP_MANIFEST" "$TMP_STAMP" "$TMP_EVIDENCE" "$TMP_STATUS" \
    "$TMP_RESOURCE_CODE" "$TMP_RESOURCE_WEB"
  [ -z "$TMP_NOTARY_ARCHIVE" ] || /bin/rm -f "$TMP_NOTARY_ARCHIVE"
  [ -z "$TMP_NOTARY_RESULT" ] || /bin/rm -f "$TMP_NOTARY_RESULT"
  cd "$INSTALL_HOME" 2>/dev/null || cleanup_status=1
  if [ -n "$SOURCE_SNAPSHOT" ]; then
    remove_source_snapshot "$SOURCE_SNAPSHOT" || cleanup_status=1
    SOURCE_SNAPSHOT=
  fi
  release_deployment_lease || cleanup_status=1
  exit "$cleanup_status"
}
trap cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15

UNSIGNED_RELEASE_HASH=$(stage_stable_executable "$BIN" "$TMP_BINARY") \
  || die "cannot stably stage and hash the unsigned release artifact"
require_deployment_lease exclusive
PUBLISHED_UNSIGNED_HASH=$(publish_unsigned_artifact "$REPO" "$TMP_BINARY") \
  || die "cannot retain the exact unsigned release artifact for evidence finalization"
[ "$PUBLISHED_UNSIGNED_HASH" = "$UNSIGNED_RELEASE_HASH" ] \
  || die "retained unsigned artifact did not match the private build snapshot"
READ_BACK_UNSIGNED_HASH=$(retained_unsigned_artifact_sha256 "$REPO" "$UNSIGNED_RELEASE_HASH") \
  || die "cannot read back the retained unsigned release artifact"
[ "$READ_BACK_UNSIGNED_HASH" = "$UNSIGNED_RELEASE_HASH" ] \
  || die "retained unsigned artifact bytes did not match the private build snapshot"
if [ "$SIGN_IDENTITY" = - ]; then
  /usr/bin/codesign --force --sign - "$TMP_BINARY" >/dev/null 2>&1 || die "ad-hoc codesign failed"
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$TMP_BINARY" >/dev/null 2>&1 \
    || die "Developer ID codesign with hardened runtime and secure timestamp failed"
fi
PRODUCT_VERSION=$(python_clean - "$TMP_BINARY" <<'PY'
import os,re,selectors,signal,subprocess,sys,time
binary=sys.argv[1]
environment={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":"/var/empty","LANG":"C","LC_ALL":"C"}
def stop_group(process):
    try: os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError: return
    if process.poll() is None:
        try: process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
def probe(argument,capture=False):
    process=subprocess.Popen([binary,argument],stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,stderr=subprocess.DEVNULL,
        env=environment,start_new_session=True,close_fds=True)
    deadline=time.monotonic()+10
    data=bytearray()
    try:
        if capture:
            if process.stdout is None: raise RuntimeError()
            os.set_blocking(process.stdout.fileno(),False)
            selector=selectors.DefaultSelector(); selector.register(process.stdout,selectors.EVENT_READ)
            try:
                while selector.get_map():
                    remaining=deadline-time.monotonic()
                    if remaining<=0: raise TimeoutError()
                    for key,_ in selector.select(min(0.2,remaining)):
                        try: chunk=os.read(key.fileobj.fileno(),4096)
                        except BlockingIOError: continue
                        if not chunk: selector.unregister(key.fileobj); continue
                        data.extend(chunk)
                        if len(data)>256: raise OverflowError()
            finally: selector.close()
        remaining=deadline-time.monotonic()
        if remaining<=0: raise TimeoutError()
        process.wait(timeout=remaining)
        if process.returncode: raise RuntimeError()
        return bytes(data)
    finally:
        stop_group(process)
        if process.stdout is not None: process.stdout.close()
try:
    probe("--help")
    raw=probe("--version",True)
    text=raw.decode("ascii").strip()
except (OSError,UnicodeDecodeError,RuntimeError,TimeoutError,OverflowError,subprocess.SubprocessError):
    raise SystemExit(1)
semver=r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
match=re.fullmatch("kist ("+semver+")",text)
if not match: raise SystemExit(1)
print(match.group(1))
PY
) || die "the freshly built binary failed its bounded --help/--version probes"
SIGNING_OUTPUT=$(signing_state "$TMP_BINARY") || die "cannot inspect the freshly signed payload"
SIGNING_TYPE=$(printf '%s\n' "$SIGNING_OUTPUT" | /usr/bin/awk -F= '$1=="signing-type" {if(seen++)exit 2;v=substr($0,14)} END{if(seen!=1)exit 3;print v}') || die "signing inspection omitted type"
SIGNING_IDENTITY=$(printf '%s\n' "$SIGNING_OUTPUT" | /usr/bin/awk -F= '$1=="signing-identity" {if(seen++)exit 2;v=substr($0,18)} END{if(seen!=1)exit 3;print v}') || die "signing inspection omitted identity"
NOTARIZATION_STATUS=$(printf '%s\n' "$SIGNING_OUTPUT" | /usr/bin/awk -F= '$1=="notarization-status" {if(seen++)exit 2;v=substr($0,21)} END{if(seen!=1)exit 3;print v}') || die "signing inspection omitted notarization"
NOTARIZATION_SUBMISSION_ID=none
NOTARIZATION_PACKAGE_HASH=none
if [ -n "$NOTARY_PROFILE" ]; then
  [ "$SIGNING_TYPE" = developer-id ] || die "notarization requires an actual Developer ID Application signature"
  SIGNED_BEFORE_NOTARY=$(sha256_file "$TMP_BINARY") || die "cannot hash the signed notarization candidate"
  TMP_NOTARY_ARCHIVE=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-notary-archive.XXXXXX")
  TMP_NOTARY_RESULT=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-notary-result.XXXXXX")
  /bin/chmod -N "$TMP_NOTARY_ARCHIVE" "$TMP_NOTARY_RESULT" 2>/dev/null || true
  /bin/rm -f "$TMP_NOTARY_ARCHIVE"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$TMP_BINARY" "$TMP_NOTARY_ARCHIVE" \
    || die "cannot package the signed payload for notarization"
  /bin/chmod 600 "$TMP_NOTARY_ARCHIVE" "$TMP_NOTARY_RESULT"
  NOTARIZATION_PACKAGE_HASH=$(sha256_file "$TMP_NOTARY_ARCHIVE") || die "cannot hash the notarization package"
  /usr/bin/xcrun notarytool submit "$TMP_NOTARY_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$TMP_NOTARY_RESULT" 2>/dev/null \
    || die "notary service rejected or could not evaluate the signed payload"
  NOTARIZATION_SUBMISSION_ID=$(python_clean - "$TMP_NOTARY_RESULT" <<'PY'
import json,re,sys
with open(sys.argv[1],"rb") as stream: raw=stream.read(1024*1024+1)
if len(raw)>1024*1024: raise SystemExit(1)
value=json.loads(raw)
if type(value) is not dict or value.get("status")!="Accepted": raise SystemExit(1)
identifier=value.get("id")
if type(identifier) is not str or not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",identifier): raise SystemExit(1)
print(identifier.lower())
PY
  ) || die "notary response was not a canonical accepted submission"
  SIGNED_AFTER_NOTARY=$(sha256_file "$TMP_BINARY") || die "cannot rehash the notarized payload"
  [ "$SIGNED_AFTER_NOTARY" = "$SIGNED_BEFORE_NOTARY" ] || die "the staged payload changed during notarization"
  notarization_attempt=0
  while [ "$notarization_attempt" -lt 5 ]; do
    SIGNING_OUTPUT=$(signing_state "$TMP_BINARY") || die "cannot re-inspect the notarized payload"
    NOTARIZATION_STATUS=$(printf '%s\n' "$SIGNING_OUTPUT" | /usr/bin/awk -F= '$1=="notarization-status" {if(seen++)exit 2;v=substr($0,21)} END{if(seen!=1)exit 3;print v}') || die "notarization inspection omitted status"
    [ "$NOTARIZATION_STATUS" = accepted ] && break
    notarization_attempt=$((notarization_attempt + 1)); /bin/sleep 2
  done
  [ "$NOTARIZATION_STATUS" = accepted ] \
    || die "notary accepted the standalone payload, but online Gatekeeper acceptance is not yet observable"
  /bin/rm -f "$TMP_NOTARY_ARCHIVE" "$TMP_NOTARY_RESULT"
  TMP_NOTARY_ARCHIVE=
  TMP_NOTARY_RESULT=
elif [ "$NOTARIZATION_STATUS" = accepted ]; then
  die "Gatekeeper reports notarization, but no retained notary submission was requested; use --notary-keychain-profile"
fi
# Exercise a real code path in the RELEASE binary, not just argv parsing: the suite runs in debug,
# so release-only miscompiles (e.g. optimizer-invalidated pointer lifetimes) slip past a green
# suite and a --help smoke. --list-providers walks config, key store, and the provider catalog.
"$TMP_BINARY" --list-providers 9>&- >/dev/null 2>&1 \
  || die "the freshly built release binary failed its --list-providers functional smoke"
# All release smokes passed — only now is it honest to claim them in the manifest evidence.
TEST_EVIDENCE="${TEST_EVIDENCE}+smoke:--help,--version,--list-providers"

stage_stable_executable "$BUILD_ROOT/scripts/kist-wrapper" "$TMP_WRAPPER" >/dev/null \
  || die "cannot stably stage the canonical wrapper"
stage_stable_executable "$BUILD_ROOT/scripts/kist-dashboard" "$TMP_DASHBOARD" >/dev/null \
  || die "cannot stably stage the canonical dashboard"
stage_stable_executable "$BUILD_ROOT/scripts/kist-rebuild" "$TMP_REBUILD" >/dev/null \
  || die "cannot stably stage the canonical rebuild gate"
stage_stable_executable "$BUILD_ROOT/scripts/kist-safe-rebuild.sh" "$TMP_SAFE_REBUILD" >/dev/null \
  || die "cannot stably stage the canonical safe-rebuild helper"

# SwiftPM's release directory is a convenience symlink inside the private snapshot. Resolve it
# once, then require the complete built bundle to match the frozen source resource bytes.
resource_python "$BUILD_ROOT" "$INSTALL_HOME/bin" "$TMP_RESOURCE_CODE" "$TMP_RESOURCE_WEB" <<'PY' \
  || die "built resource inventory does not match the private source snapshot"
root,bindir,*destinations=sys.argv[1:]
if len(destinations)!=len(RESOURCE_FILES): raise SystemExit(1)
bundle=os.path.realpath(os.path.join(root,".build/release",RESOURCE_ROOT))
if not bundle.startswith(root+"/"): raise SystemExit(1)
built=resource_tree(bundle)
source_root=os.path.join(root,"Sources/AgentCore/Skills")
source=resource_tree(os.path.join(source_root,"builtin"),builtin_only=True)
# The Skills directory also contains Swift sources; bind the complete copied builtin subtree.
for alias,destination in zip(RESOURCE_FILES,destinations):
    raw,_=source[alias]
    if raw!=built[alias][0]: raise SystemExit(1)
    if os.path.dirname(destination)!=bindir: raise SystemExit(1)
    before=os.lstat(destination)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid!=os.geteuid()
            or before.st_nlink!=1 or stat.S_IMODE(before.st_mode)!=0o600): raise SystemExit(1)
    fd=os.open(destination,os.O_WRONLY|os.O_NOFOLLOW)
    try:
        if resource_fp(os.fstat(fd))!=resource_fp(before): raise SystemExit(1)
        resource_acl(fd); os.ftruncate(fd,0)
        offset=0
        while offset<len(raw):
            written=os.write(fd,raw[offset:])
            if written<=0: raise SystemExit(1)
            offset+=written
        os.fchmod(fd,0o644); os.fsync(fd)
    finally: os.close(fd)
if built!=resource_tree(bundle): raise SystemExit(1)
if source!=resource_tree(os.path.join(source_root,"builtin"),builtin_only=True): raise SystemExit(1)
PY

FULL_SHA=$(git_repo rev-parse HEAD) || die "cannot read full Git commit"
[ "$FULL_SHA" = "$BUILD_COMMIT" ] || die "Git commit changed during the release build; retry"
SHORT_SHA=$(git_repo rev-parse --short=12 HEAD) || die "cannot read short Git commit"
BRANCH=$(git_repo rev-parse --abbrev-ref HEAD) || die "cannot read Git branch"
TOP=$(git_repo rev-parse --show-toplevel) || die "cannot read Git worktree root"
TOP=$(validated_repo "$TOP") || die "Git top level is not the selected Kist repo"
[ "$TOP" = "$REPO" ] || die "selected repo does not match its Git top level"
COMMON_RAW=$(git_repo rev-parse --git-common-dir) || die "cannot read Git common directory"
case "$COMMON_RAW" in /*) COMMON_PATH=$COMMON_RAW ;; *) COMMON_PATH="$REPO/$COMMON_RAW" ;; esac
COMMON=$(cd -P -- "$COMMON_PATH" 2>/dev/null && pwd) || die "cannot canonicalize Git common directory"
REMOTE=$(git_repo config --get remote.origin.url 2>/dev/null || printf '%s' '(none)')
REMOTE_HASH=$(python_clean - "$REMOTE" <<'PY'
import hashlib,sys
value=sys.argv[1]
if not value or any(c.isspace() or c=="\0" for c in value): raise SystemExit(1)
cuts=[i for i in (value.find("?"),value.find("#")) if i>=0]
value=value[:min(cuts)] if cuts else value
if "://" in value:
    scheme,rest=value.split("://",1); authority,sep,path=rest.partition("/"); authority=authority.rsplit("@",1)[-1]
    if not scheme or not authority: raise SystemExit(1)
    value=scheme.lower()+"://"+authority.lower()+(sep+path if sep else "")
else:
    colon=value.find(":"); slash=value.find("/")
    if colon>=0 and (slash<0 or colon<slash):
        host=value[:colon].rsplit("@",1)[-1]
        if not host: raise SystemExit(1)
        value=host.lower()+value[colon:]
print(hashlib.sha256(value.encode()).hexdigest())
PY
) || die "remote origin is not a canonical credential-free identity"
REPOSITORY_ID=$(printf '%s\n%s\n' "$REMOTE_HASH" "$COMMON" | "$SHASUM" -a 256 | /usr/bin/awk '{print $1}')

# Repository-root usage telemetry and per-run proof streams are operational state, even where
# legacy history tracked them. Other root .kist content (agents, policy/learning, and plan inputs)
# remains part of both the source snapshot and the dirty projection.
git_repo status --porcelain=v1 --untracked-files=all -- . \
  ':(exclude,top).kist/usage.jsonl' \
  ':(exclude,top).kist/runs' ':(exclude,top).kist/runs/**' > "$TMP_STATUS" \
  || die "cannot inspect Git status"
if [ -s "$TMP_STATUS" ]; then SOURCE_DIRTY=yes; else SOURCE_DIRTY=no; fi
STATE_AFTER=$(source_state "$REPO") || die "cannot hash the final source state"
[ "$BUILD_SOURCE_STATE" = "$STATE_AFTER" ] \
  || die "source tree changed while deployment metadata was being captured; retry"

CLOSURE_OUTPUT=$("$TMP_DASHBOARD" --provenance-evaluate "$TMP_BINARY" "$TMP_WRAPPER" \
  "$TMP_DASHBOARD" "$TMP_REBUILD" "$TMP_SAFE_REBUILD" "$TMP_RESOURCE_CODE" "$TMP_RESOURCE_WEB" 9>&-) \
  || die "cannot compute the deployment artifact closure"
closure_value() {
  printf '%s\n' "$CLOSURE_OUTPUT" | /usr/bin/awk -F= -v key="$1" '$1==key { if (seen++) exit 2; print substr($0,length(key)+2) } END { if (!seen) exit 3 }'
}
BINARY_HASH=$(closure_value binary-sha256) || die "missing binary closure hash"
WRAPPER_HASH=$(closure_value wrapper-sha256) || die "missing wrapper closure hash"
LAUNCHER_HASH=$(closure_value dashboard-launcher-sha256) || die "missing dashboard closure hash"
REBUILD_HASH=$(closure_value rebuild-sha256) || die "missing rebuild closure hash"
SAFE_REBUILD_HASH=$(closure_value safe-rebuild-sha256) || die "missing safe-rebuild closure hash"
RESOURCE_CODE_HASH=$(closure_value resource-code-investigation-sha256) || die "missing code resource hash"
RESOURCE_WEB_HASH=$(closure_value resource-web-research-sha256) || die "missing web resource hash"
DASHBOARD_RUNTIME_HASH=$(closure_value dashboard-runtime-sha256) || die "missing dashboard runtime hash"
DASHBOARD_CORTEX_HASH=$(closure_value dashboard-cortex-sha256) || die "missing dashboard cortex tree hash"
DASHBOARD_CORTEX_COUNT=$(closure_value dashboard-cortex-count) || die "missing dashboard cortex tree count"
ARTIFACT_CLOSURE_HASH=$(closure_value artifact-closure-sha256) || die "missing aggregate closure hash"
ARTIFACT_CLOSURE_COUNT=$(closure_value artifact-closure-count) || die "missing aggregate closure count"
python_clean - "$STATE_AFTER" "$UNSIGNED_RELEASE_HASH" "$BINARY_HASH" "$PRODUCT_VERSION" > "$TMP_EVIDENCE" <<'PY'
import json,sys
source,unsigned,signed,version=sys.argv[1:]
payload={"schema":1,"assurance":"pilot","provenance_kind":"local-candidate","product_version":version,"source_state_sha256":source,"unsigned_release_sha256":unsigned,"signed_installed_sha256":signed}
print(json.dumps(payload,sort_keys=True,separators=(",",":"),ensure_ascii=True))
PY
DEPLOYMENT_EVIDENCE_HASH=$(sha256_file "$TMP_EVIDENCE") || die "cannot hash pilot provenance evidence"
DEPLOYED_AT=$(/bin/date '+%Y-%m-%d %H:%M:%S')
STAMP="$SHORT_SHA · $BRANCH · $DEPLOYED_AT · $REPO"

{
  printf 'schema: 4\n'
  printf 'stamp: %s\n' "$STAMP"
  printf 'deployed: %s\n' "$DEPLOYED_AT"
  printf 'worktree: %s\n' "$REPO"
  printf 'branch: %s\n' "$BRANCH"
  printf 'commit: %s\n' "$FULL_SHA"
  printf 'remote-origin-sha256: %s\n' "$REMOTE_HASH"
  printf 'repository-id: %s\n' "$REPOSITORY_ID"
  printf 'source-dirty: %s\n' "$SOURCE_DIRTY"
  printf 'source-state-sha256: %s\n' "$STATE_AFTER"
  printf 'binary-sha256: %s\n' "$BINARY_HASH"
  printf 'wrapper-sha256: %s\n' "$WRAPPER_HASH"
  printf 'dashboard-launcher-sha256: %s\n' "$LAUNCHER_HASH"
  printf 'rebuild-sha256: %s\n' "$REBUILD_HASH"
  printf 'safe-rebuild-sha256: %s\n' "$SAFE_REBUILD_HASH"
  printf 'resource-code-investigation-sha256: %s\n' "$RESOURCE_CODE_HASH"
  printf 'resource-web-research-sha256: %s\n' "$RESOURCE_WEB_HASH"
  printf 'dashboard-runtime-sha256: %s\n' "$DASHBOARD_RUNTIME_HASH"
  printf 'dashboard-cortex-sha256: %s\n' "$DASHBOARD_CORTEX_HASH"
  printf 'dashboard-cortex-count: %s\n' "$DASHBOARD_CORTEX_COUNT"
  printf 'artifact-closure-sha256: %s\n' "$ARTIFACT_CLOSURE_HASH"
  printf 'artifact-closure-count: %s\n' "$ARTIFACT_CLOSURE_COUNT"
  printf 'test-evidence: %s\n' "$TEST_EVIDENCE"
  printf 'deployment-assurance: pilot\n'
  printf 'provenance-kind: local-candidate\n'
  printf 'product-version: %s\n' "$PRODUCT_VERSION"
  printf 'unsigned-release-sha256: %s\n' "$UNSIGNED_RELEASE_HASH"
  printf 'signed-installed-sha256: %s\n' "$BINARY_HASH"
  printf 'signing-type: %s\n' "$SIGNING_TYPE"
  printf 'signing-identity: %s\n' "$SIGNING_IDENTITY"
  printf 'notarization-status: %s\n' "$NOTARIZATION_STATUS"
  printf 'notarization-submission-id: %s\n' "$NOTARIZATION_SUBMISSION_ID"
  printf 'notarization-package-sha256: %s\n' "$NOTARIZATION_PACKAGE_HASH"
  printf 'deployment-evidence-sha256: %s\n' "$DEPLOYMENT_EVIDENCE_HASH"
} > "$TMP_MANIFEST"
printf '%s\n' "$STAMP" > "$TMP_STAMP"
/bin/chmod 600 "$TMP_MANIFEST" "$TMP_STAMP" "$TMP_EVIDENCE" "$TMP_STATUS"

python_clean - "$TMP_BINARY" "$TMP_WRAPPER" "$TMP_DASHBOARD" "$TMP_REBUILD" "$TMP_SAFE_REBUILD" \
  "$TMP_MANIFEST" "$TMP_STAMP" "$TMP_EVIDENCE" "$TMP_RESOURCE_CODE" "$TMP_RESOURCE_WEB" "$INSTALL_HOME/bin" <<'PY'
import os,sys
for path in sys.argv[1:-1]:
    fd=os.open(path,os.O_RDONLY); os.fsync(fd); os.close(fd)
fd=os.open(sys.argv[-1],os.O_RDONLY); os.fsync(fd); os.close(fd)
PY

# Backups and a durable journal precede every replacement. Any error or signal before commit runs
# rollback under the same exclusive lease; SIGKILL is recovered by the next exclusive rebuild.
TRANSACTION_ACTIVE=1
TRANSACTION_TOKEN=$(transaction_control begin "$TMP_BINARY" "$TMP_WRAPPER" "$TMP_DASHBOARD" \
  "$TMP_REBUILD" "$TMP_SAFE_REBUILD" "$TMP_MANIFEST" "$TMP_STAMP" "$TMP_EVIDENCE" \
  "$TMP_RESOURCE_CODE" "$TMP_RESOURCE_WEB") \
  || die "transactional promotion could not be started"
[ -n "$TRANSACTION_TOKEN" ] || die "transactional promotion omitted its identity"
if [ "${KIST_REBUILD_TESTING-}" = 1 ] && [ "${KIST_REBUILD_TEST_INTERRUPT_AFTER-}" = activation ]; then
  [ "$INSTALL_HOME" != /Users/lukekist ] || die "test interruption hooks are forbidden for production"
  /bin/kill -TERM "$$"
fi
if [ "${KIST_REBUILD_TESTING-}" = 1 ] && [ -n "${KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK-}" ]; then
  [ "$INSTALL_HOME" != /Users/lukekist ] || die "after-activation test hooks are forbidden for production"
  case "$KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK" in
    /*) ;;
    *) die "after-activation test hook must be absolute" ;;
  esac
  [ -x "$KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK" ] \
    && [ ! -L "$KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK" ] \
    || die "after-activation test hook is not one executable regular file"
  if [ "${KIST_REBUILD_TEST_CLOSE_DEPLOYMENT_LEASE_AFTER_ACTIVATION-}" = 1 ]; then
    exec 9>&-
  fi
  /usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" LANG=C LC_ALL=C \
    "$KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK" "$REPO" "$BUILD_ROOT" 9>&- \
    || die "after-activation test hook failed"
fi
require_deployment_lease exclusive
POST_ROOT=$(deployed_repo) || die "post-promotion schema-4 deployment validation failed"
[ "$POST_ROOT" = "$REPO" ] || die "post-promotion repository identity changed"
validate_installed_provenance_exclusive \
  || die "post-promotion evidence, signing, or artifact provenance validation failed"
/usr/bin/cmp -s "$REPO/scripts/kist-wrapper" "$INSTALL_HOME/bin/kist" \
  || die "installed wrapper bytes differ from their canonical source"
/usr/bin/cmp -s "$REPO/scripts/kist-dashboard" "$INSTALL_HOME/bin/kist-dashboard" \
  || die "installed dashboard bytes differ from their canonical source"
/usr/bin/cmp -s "$REPO/scripts/kist-rebuild" "$INSTALL_HOME/bin/kist-rebuild" \
  || die "installed rebuild bytes differ from their canonical source"
/usr/bin/cmp -s "$REPO/scripts/kist-safe-rebuild.sh" "$INSTALL_HOME/bin/kist-safe-rebuild.sh" \
  || die "installed safe-rebuild bytes differ from their canonical source"
for skill in code-investigation web-research; do
  /usr/bin/cmp -s "$BUILD_ROOT/Sources/AgentCore/Skills/builtin/$skill/SKILL.md" \
    "$INSTALL_HOME/bin/AgentCore_AgentCore.bundle/builtin/$skill/SKILL.md" \
    || die "installed resource differs from the private source snapshot: $skill"
done
"$INSTALL_HOME/bin/kist-current" --help 9>&- >/dev/null 2>&1 \
  || die "installed binary failed its post-promotion --help smoke check"
require_deployment_lease exclusive
FINAL_SOURCE_STATE=$(source_state "$REPO") \
  || die "cannot perform the final source-state compare before commit"
FINAL_HEAD=$(git_repo rev-parse HEAD) || die "cannot perform the final Git HEAD compare before commit"
FINAL_BRANCH=$(git_repo rev-parse --abbrev-ref HEAD) \
  || die "cannot perform the final Git branch compare before commit"
[ "$FINAL_SOURCE_STATE" = "$STATE_AFTER" ] && [ "$FINAL_HEAD" = "$FULL_SHA" ] \
  && [ "$FINAL_BRANCH" = "$BRANCH" ] \
  || die "source state, Git HEAD, or branch changed after activation; rolling back"
require_deployment_lease exclusive
transaction_control commit || die "deployment transaction could not be committed"
TRANSACTION_ACTIVE=0

cd "$INSTALL_HOME"
remove_source_snapshot "$SOURCE_SNAPSHOT" || die "installed deployment committed but private source snapshot cleanup failed"
SOURCE_SNAPSHOT=
trap - 0 1 2 15
cleanup_status=0
/bin/rm -f "$TMP_STATUS"
release_deployment_lease
echo "installed OK -> $INSTALL_HOME/bin/kist"
echo "   build: $STAMP"
