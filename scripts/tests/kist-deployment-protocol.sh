#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO_ROOT=$(cd -P -- "$(dirname "$0")/../.." && pwd)
REBUILD_SOURCE=${KIST_REBUILD_UNDER_TEST:-$REPO_ROOT/scripts/kist-rebuild}
DASHBOARD_SOURCE=${KIST_DASHBOARD_UNDER_TEST:-$REPO_ROOT/scripts/kist-dashboard}
SAFE_REBUILD_SOURCE=${KIST_SAFE_REBUILD_UNDER_TEST:-$REPO_ROOT/scripts/kist-safe-rebuild.sh}
[[ -x "$REBUILD_SOURCE" && -x "$DASHBOARD_SOURCE" && -x "$SAFE_REBUILD_SOURCE" ]] \
  || { printf 'missing rebuild/dashboard/safe-rebuild launchers\n' >&2; exit 1; }
TMP=$(/usr/bin/mktemp -d /Users/lukekist/.kist-release-registry-test.XXXXXX)
GLOBAL_SNAPSHOT_DECOY=""
LEASE_HOLDER_PID=""
LEASE_TEST_RELEASE=""
cleanup() {
  if [[ -n "$LEASE_HOLDER_PID" ]]; then
    [[ -z "$LEASE_TEST_RELEASE" ]] || /usr/bin/touch "$LEASE_TEST_RELEASE"
    wait "$LEASE_HOLDER_PID" 2>/dev/null || true
  fi
  if [[ -n "$GLOBAL_SNAPSHOT_DECOY" ]]; then
    /bin/rm -rf "$GLOBAL_SNAPSHOT_DECOY"
  fi
  if [[ -n "${FIXTURE-}" && -d "$FIXTURE/project/Sources/Kist/ReadOnlySnapshot" ]]; then
    /bin/chmod 700 "$FIXTURE/project/Sources/Kist/ReadOnlySnapshot/Nested" 2>/dev/null || true
    /bin/chmod 700 "$FIXTURE/project/Sources/Kist/ReadOnlySnapshot" 2>/dev/null || true
  fi
  if [[ "${KIST_KEEP_RELEASE_TEST_TMP-0}" = 1 ]]; then
    printf 'release-registry artifacts retained at %s\n' "$TMP" >&2
  else
    /bin/rm -rf "$TMP"
  fi
}
trap cleanup EXIT INT TERM
FIXTURE="$TMP/home"

/usr/bin/python3 - "$REBUILD_SOURCE" "$DASHBOARD_SOURCE" "$SAFE_REBUILD_SOURCE" "$FIXTURE" <<'PY'
from pathlib import Path
import hashlib,os,subprocess,sys
rebuild_source=Path(sys.argv[1]); dashboard_source=Path(sys.argv[2])
safe_source=Path(sys.argv[3]); home=Path(sys.argv[4])
for path in [home/"bin",home/".kist/scripts",home/".kist/cortex/live/assets",home/"project"]:
    path.mkdir(parents=True,exist_ok=True)
os.chmod(home,0o700); os.chmod(home/".kist",0o700)
project=home/"project"; (project/"fixture.txt").write_text("release registry source\n")
(project/".gitignore").write_text(".build/\n.build-local/\n")
(project/"Sources/Kist").mkdir(parents=True)
(project/"Sources/AgentCore").mkdir(parents=True)
(project/"Tests/KistTests").mkdir(parents=True)
(project/"scripts").mkdir(parents=True)
(project/"Package.swift").write_text(
    '// swift-tools-version: 5.9\n'
    'import PackageDescription\n'
    'let package = Package(name: "Fixture", products: ['
    '.executable(name: "kist", targets: ["Kist"])], targets: ['
    '.executableTarget(name: "Kist")])\n')
(project/"Sources/Kist/KistRunner.swift").write_text(
    'import Foundation\n'
    'if CommandLine.arguments.contains("--version") { print("kist 9.9.9-test.1") }\n')
(project/"Sources/AgentCore/CaptainOrchestrator.swift").write_text("// fixture\n")
(project/"Tests/KistTests/KistOptionsTests.swift").write_text("// fixture\n")
(project/"scripts/kist-rebuild").write_text("#!/bin/sh\n# tracked fixture source\n")
git_env={**os.environ,"GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":"/dev/null"}
for args in [["init"],["config","user.name","Kist Test"],["config","user.email","kist-test@example.invalid"],
             ["add","--all"],["commit","-m","fixture"],["branch","-M","main"]]:
    subprocess.run(["/usr/bin/git","-C",str(project),*args],env=git_env,
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
swiftpm_release=project/".build/arm64-apple-macosx/release"
swiftpm_release.mkdir(parents=True)
(swiftpm_release/"kist").write_text("#!/bin/sh\n# SwiftPM release sentinel\n")
(swiftpm_release/"kist").chmod(0o755)
(project/".build/release").symlink_to("arm64-apple-macosx/release",target_is_directory=True)
runtime=project/".kist"; run=runtime/"runs/1785376007-155a334c"
run.mkdir(parents=True)
(runtime/"usage.jsonl").write_text('{"fixture":"preexisting"}\n')
(run/"events.jsonl").write_text('{"event":"preexisting"}\n')
dashboard=(home/"bin/kist-dashboard")
dashboard.write_text(dashboard_source.read_text().replace(
    'readonly INSTALL_HOME="/Users/lukekist"',f'readonly INSTALL_HOME="{home}"',1))
rebuild=(home/"bin/kist-rebuild")
rebuild.write_text(rebuild_source.read_text().replace(
    'INSTALL_HOME=/Users/lukekist',f'INSTALL_HOME={home}',1))
safe=(home/"bin/kist-safe-rebuild.sh")
safe.write_text(safe_source.read_text().replace(
    'readonly INSTALL_HOME="/Users/lukekist"',f'readonly INSTALL_HOME="{home}"',1))
(home/"bin/kist").write_text(f'#!/bin/sh\nexec "{home}/bin/kist-current" "$@"\n')
(home/".kist/scripts/kist_runtime.py").write_text("#!/usr/bin/python3\n# release fixture runtime\n")
(home/".kist/cortex/live/app.py").write_text("# release fixture cortex\n")
(home/".kist/cortex/live/assets/app.js").write_text("const releaseFixture = true;\n")
for path in [dashboard,rebuild,home/"bin/kist",safe,
             home/".kist/scripts/kist_runtime.py"]:
    path.chmod(0o755)
for source,name in [
    (dashboard,"kist-dashboard"),(rebuild,"kist-rebuild"),
    (home/"bin/kist","kist-wrapper"),(safe,"kist-safe-rebuild.sh"),
]:
    target=project/"scripts"/name
    target.write_bytes(source.read_bytes()); target.chmod(0o755)
for name,code in [
    ("fixture-pass",b"int main(void){return 0;}\n"),
    ("fixture-fail",b"int main(void){return 1;}\n"),
]:
    target=home/name
    subprocess.run(["/usr/bin/clang","-x","c","-","-o",str(target)],input=code,check=True)
    subprocess.run(["/usr/bin/codesign","--force","--sign","-",str(target)],
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
PY

install_release() {
  local version=$1 binary_source=$2 deployed=$3 source_tag=$4 closure_kind=${5:-v3}
  /bin/cp "$binary_source" "$FIXTURE/bin/kist-current"
  /bin/chmod 755 "$FIXTURE/bin/kist-current"
  /bin/cp "$SAFE_REBUILD_SOURCE" "$FIXTURE/bin/kist-safe-rebuild.sh"
  printf '\n# fixture-release: %s\n' "$source_tag" >> "$FIXTURE/bin/kist-safe-rebuild.sh"
  /bin/chmod 755 "$FIXTURE/bin/kist-safe-rebuild.sh"
  if [[ "$closure_kind" == v3 ]]; then
    "$FIXTURE/bin/kist-dashboard" --provenance-evaluate \
      "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
      "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" > "$TMP/closure"
  elif [[ "$closure_kind" == legacy ]]; then
    "$FIXTURE/bin/kist-dashboard" --provenance-evaluate \
      "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
      "$FIXTURE/bin/kist-rebuild" > "$TMP/closure"
  else
    printf 'unknown fixture closure: %s\n' "$closure_kind" >&2
    exit 1
  fi
  "$FIXTURE/bin/kist-rebuild" --signing-evaluate "$FIXTURE/bin/kist-current" > "$TMP/signing"
  /usr/bin/python3 - "$FIXTURE" "$version" "$deployed" "$source_tag" \
    "$TMP/closure" "$TMP/signing" <<'PY'
from pathlib import Path
import hashlib,json,os,subprocess,sys
home=Path(sys.argv[1]); version,deployed,source_tag=sys.argv[2:5]
closure_path=Path(sys.argv[5]); signing_path=Path(sys.argv[6]); project=home/"project"
git_env={**os.environ,"GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":"/dev/null"}
def git(*args):
    return subprocess.run(["/usr/bin/git","-C",str(project),*args],env=git_env,
                          stdout=subprocess.PIPE,text=True,check=True).stdout.strip()
commit=git("rev-parse","HEAD"); short=commit[:12]; common=os.path.realpath(project/".git")
remote_hash=hashlib.sha256(b"(none)").hexdigest()
repository_id=hashlib.sha256(f"{remote_hash}\n{common}\n".encode()).hexdigest()
closure=dict(line.split("=",1) for line in closure_path.read_text().splitlines())
signing=dict(line.split("=",1) for line in signing_path.read_text().splitlines())
source_state=hashlib.sha256(("source:"+source_tag).encode()).hexdigest()
unsigned=hashlib.sha256(("unsigned:"+source_tag).encode()).hexdigest()
evidence={"schema":1,"assurance":"pilot","provenance_kind":"local-candidate",
          "product_version":version,"source_state_sha256":source_state,
          "unsigned_release_sha256":unsigned,
          "signed_installed_sha256":closure["binary-sha256"]}
evidence_raw=(json.dumps(evidence,sort_keys=True,separators=(",",":"))+"\n").encode()
(home/"bin/kist-current.provenance.json").write_bytes(evidence_raw)
stamp=f"{short} · main · {deployed} · {project}"
fields={
 "schema":"4","stamp":stamp,"deployed":deployed,"worktree":str(project),"branch":"main","commit":commit,
 "remote-origin-sha256":remote_hash,"repository-id":repository_id,"source-dirty":"no",
 "source-state-sha256":source_state,"binary-sha256":closure["binary-sha256"],
 "wrapper-sha256":closure["wrapper-sha256"],"dashboard-launcher-sha256":closure["dashboard-launcher-sha256"],
 "rebuild-sha256":closure["rebuild-sha256"],
 "artifact-closure-sha256":closure["artifact-closure-sha256"],
 "artifact-closure-count":closure["artifact-closure-count"],"test-evidence":"fixture:release-registry",
 "deployment-assurance":"pilot","provenance-kind":"local-candidate","unsigned-release-sha256":unsigned,
 "signed-installed-sha256":closure["binary-sha256"],"signing-type":signing["signing-type"],
 "signing-identity":signing["signing-identity"],"notarization-status":signing["notarization-status"],
 "notarization-submission-id":"none","notarization-package-sha256":"none",
 "deployment-evidence-sha256":hashlib.sha256(evidence_raw).hexdigest(),"product-version":version,
}
if "safe-rebuild-sha256" in closure:
    fields["safe-rebuild-sha256"]=closure["safe-rebuild-sha256"]
    payload_identity="safe-rebuild-sha256"
else:
    fields["dashboard-runtime-sha256"]=closure["dashboard-runtime-sha256"]
    payload_identity="dashboard-runtime-sha256"
order=["schema","stamp","deployed","worktree","branch","commit","remote-origin-sha256","repository-id",
       "source-dirty","source-state-sha256","binary-sha256","wrapper-sha256",
       "dashboard-launcher-sha256","rebuild-sha256",payload_identity,
       "artifact-closure-sha256","artifact-closure-count","test-evidence","deployment-assurance",
       "provenance-kind","unsigned-release-sha256","signed-installed-sha256","signing-type",
       "signing-identity","notarization-status","notarization-submission-id",
       "notarization-package-sha256","deployment-evidence-sha256","product-version"]
(home/"bin/kist-current.manifest").write_text("".join(f"{key}: {fields[key]}\n" for key in order))
(home/"bin/.kist-build").write_text(stamp+"\n")
for path in [home/"bin/kist-current.manifest",home/"bin/.kist-build",
             home/"bin/kist-current.provenance.json"]:
    path.chmod(0o600)
PY
  "$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null
}

json_value() {
  /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}
expect_reject() {
  local label=$1
  shift
  if "$@" >"$TMP/reject-$label.out" 2>"$TMP/reject-$label.err"; then
    printf 'invalid release operation unexpectedly accepted: %s\n' "$label" >&2
    exit 1
  fi
}

# Materialize the exact seven-file registry shape produced by the previous release gate.  New code
# deliberately refuses to create fresh legacy archives, so compatibility has to be exercised with
# an authentic old record rather than weakening the production archive policy.
archive_legacy_fixture() {
  /usr/bin/python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import datetime,hashlib,json,os,shutil,sys,time

home=Path(sys.argv[1]); bindir=home/"bin"
releases=home/".kist/release-registry/releases"
targets=["kist-current","kist","kist-dashboard","kist-rebuild",
         "kist-current.manifest",".kist-build","kist-current.provenance.json"]
executables={"kist-current","kist","kist-dashboard","kist-rebuild"}

def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode()
def parse_manifest(path):
    fields={}
    for line in path.read_text().splitlines():
        key,value=line.split(":",1); fields[key.strip().lower()]=value.strip()
    return fields

files=[]
for name in targets:
    path=bindir/name; raw=path.read_bytes()
    files.append({"bytes":len(raw),"mode":path.stat().st_mode&0o777,"name":name,
                  "sha256":hashlib.sha256(raw).hexdigest()})
digest=hashlib.sha256(b"kist-release-registry-v1\0")
for item in files:
    name=item["name"].encode()
    digest.update(len(name).to_bytes(8,"big")); digest.update(name)
    digest.update(item["mode"].to_bytes(4,"big"))
    digest.update(item["bytes"].to_bytes(8,"big"))
    digest.update(bytes.fromhex(item["sha256"]))
identifier=digest.hexdigest()
manifest=parse_manifest(bindir/"kist-current.manifest")
timestamp_ns=time.time_ns()
timestamp=datetime.datetime.fromtimestamp(
    timestamp_ns/1_000_000_000,datetime.timezone.utc
).isoformat(timespec="microseconds").replace("+00:00","Z")
record={"approved_by_uid":os.geteuid(),"archived_at":timestamp,
        "archived_at_unix_ns":timestamp_ns,"assurance":manifest["deployment-assurance"],
        "commit":manifest["commit"],"files":files,"product_version":manifest["product-version"],
        "release_id":identifier,"schema":1,
        "source_state_sha256":manifest["source-state-sha256"],"stamp":manifest["stamp"]}
directory=releases/("release-"+identifier); files_dir=directory/"files"
files_dir.mkdir(parents=True,mode=0o700)
os.chmod(releases.parent,0o700); os.chmod(releases,0o700)
os.chmod(directory,0o700); os.chmod(files_dir,0o700)
for item in files:
    source=bindir/item["name"]; target=files_dir/item["name"]
    shutil.copyfile(source,target); os.chmod(target,item["mode"])
(directory/"record.json").write_bytes(canonical(record))
os.chmod(directory/"record.json",0o600)
print(identifier)
PY
}

# Repository-local runtime telemetry survives promotion and is not part of the reproducible source
# identity.  A tracked script still changes that identity, so the exclusion cannot hide source
# edits or a nested source subtree.
SOURCE_STATE_BEFORE=$("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project")
printf '{"fixture":"still-running"}\n' >> "$FIXTURE/project/.kist/usage.jsonl"
/bin/mkdir -p "$FIXTURE/project/.kist/runs/1785376008-255a334c"
printf '{"event":"still-running"}\n' \
  > "$FIXTURE/project/.kist/runs/1785376008-255a334c/events.jsonl"
SOURCE_STATE_AFTER_RUNTIME=$("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project")
[[ "$SOURCE_STATE_AFTER_RUNTIME" = "$SOURCE_STATE_BEFORE" ]]
[[ -z $(/usr/bin/git -C "$FIXTURE/project" status --porcelain=v1 --untracked-files=all -- . \
  ':(exclude,top).kist/usage.jsonl' \
  ':(exclude,top).kist/runs' ':(exclude,top).kist/runs/**') ]]
RUNTIME_USAGE_HASH=$(/usr/bin/shasum -a 256 "$FIXTURE/project/.kist/usage.jsonl" \
  | /usr/bin/awk '{print $1}')

# The ignored root alternate SwiftPM cache is not source and may contain SwiftPM's convenience
# symlink. The same name nested under Sources remains source.
/bin/mkdir -p "$FIXTURE/project/.build-local/arm64-apple-macosx/debug"
printf 'ignored SwiftPM cache\n' \
  > "$FIXTURE/project/.build-local/arm64-apple-macosx/debug/cache-entry"
/bin/ln -s arm64-apple-macosx/debug "$FIXTURE/project/.build-local/debug"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") = "$SOURCE_STATE_BEFORE" ]]
/bin/mkdir -p "$FIXTURE/project/Sources/Kist/.build-local"
printf '// nested alternate build name remains source\n' \
  > "$FIXTURE/project/Sources/Kist/.build-local/Hidden.swift"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") != "$SOURCE_STATE_BEFORE" ]]
/bin/mv "$FIXTURE/project/Sources/Kist/.build-local" "$TMP/nested-build-local-probe"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") = "$SOURCE_STATE_BEFORE" ]]

/bin/cp "$FIXTURE/project/scripts/kist-rebuild" "$TMP/tracked-script"
printf '# source mutation\n' >> "$FIXTURE/project/scripts/kist-rebuild"
SOURCE_STATE_AFTER_SOURCE=$("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project")
[[ "$SOURCE_STATE_AFTER_SOURCE" != "$SOURCE_STATE_BEFORE" ]]
[[ $(/usr/bin/git -C "$FIXTURE/project" status --porcelain=v1 --untracked-files=all -- . \
  ':(exclude,top).kist' ':(exclude,top).kist/**') == *"scripts/kist-rebuild"* ]]
/bin/cp "$TMP/tracked-script" "$FIXTURE/project/scripts/kist-rebuild"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") = "$SOURCE_STATE_BEFORE" ]]
/bin/mkdir -p "$FIXTURE/project/Sources/Kist/.kist"
printf '// nested source cannot hide behind the runtime directory name\n' \
  > "$FIXTURE/project/Sources/Kist/.kist/Hidden.swift"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") != "$SOURCE_STATE_BEFORE" ]]
/bin/mkdir -p "$FIXTURE/project/.kist/agents"
/bin/mv "$FIXTURE/project/Sources/Kist/.kist" \
  "$FIXTURE/project/.kist/agents/nested-source-probe"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") != "$SOURCE_STATE_BEFORE" ]]
[[ $(/usr/bin/git -C "$FIXTURE/project" status --porcelain=v1 --untracked-files=all -- . \
  ':(exclude,top).kist/usage.jsonl' \
  ':(exclude,top).kist/runs' ':(exclude,top).kist/runs/**') == *".kist/agents"* ]]
/bin/mv "$FIXTURE/project/.kist/agents/nested-source-probe" "$TMP/nested-source-probe"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") = "$SOURCE_STATE_BEFORE" ]]

# The production snapshot retains child directory modes. These nested read-only directories exercise
# the normal post-build remove_source_snapshot path: successful or rejected promotion must still
# remove its private snapshot without weakening the canonical source tree.
READ_ONLY_SOURCE_PARENT="$FIXTURE/project/Sources/Kist/ReadOnlySnapshot"
/bin/mkdir -m 700 "$READ_ONLY_SOURCE_PARENT"
/bin/mkdir -m 700 "$READ_ONLY_SOURCE_PARENT/Nested"
/bin/chmod 550 "$READ_ONLY_SOURCE_PARENT/Nested"
/bin/chmod 555 "$READ_ONLY_SOURCE_PARENT"
[[ $(/usr/bin/stat -f '%Lp' "$READ_ONLY_SOURCE_PARENT") = 555 ]]
[[ $(/usr/bin/stat -f '%Lp' "$READ_ONLY_SOURCE_PARENT/Nested") = 550 ]]

# Archive two coherent releases. Approval is the exact current release digest, not a short label.
install_release "1.0.0-alpha" "$FIXTURE/fixture-pass" "2026-07-24 10:00:00" alpha
A_STATUS=$("$FIXTURE/bin/kist-rebuild" --release-status)
A_ID=$(printf '%s' "$A_STATUS" | json_value current_release_id)
[[ "$A_ID" =~ ^[a-f0-9]{64}$ ]] || { printf 'invalid alpha release id\n' >&2; exit 1; }

# The short acquisition process exits before this ready marker is published (the coordinating
# child proves fd 9 is closed). The independent open below must still be excluded by the shell's
# descriptor, and must acquire immediately once that shell releases it.
LEASE_TEST_READY="$TMP/parent-lease-ready"
LEASE_TEST_RELEASE="$TMP/parent-lease-release"
/usr/bin/env KIST_REBUILD_TESTING=1 \
  "$FIXTURE/bin/kist-rebuild" --test-hold-deployment-lease \
  "$LEASE_TEST_READY" "$LEASE_TEST_RELEASE" \
  >"$TMP/parent-lease-holder.out" 2>"$TMP/parent-lease-holder.err" &
LEASE_HOLDER_PID=$!
for _ in {1..500}; do
  [[ -s "$LEASE_TEST_READY" ]] && break
  /bin/kill -0 "$LEASE_HOLDER_PID" 2>/dev/null || break
  /bin/sleep .02
done
[[ -s "$LEASE_TEST_READY" ]] || {
  /bin/cat "$TMP/parent-lease-holder.err" >&2
  printf 'parent-owned deployment lease holder did not become ready\n' >&2
  exit 1
}
/usr/bin/python3 -I - "$FIXTURE/bin/.kist-deployment.lock" blocked <<'PY'
import fcntl,os,sys
path,expectation=sys.argv[1:]
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
try:
    try: fcntl.flock(fd,fcntl.LOCK_SH|fcntl.LOCK_NB)
    except BlockingIOError: blocked=True
    else: blocked=False
finally:
    os.close(fd)
raise SystemExit(0 if blocked==(expectation=="blocked") else 1)
PY
/usr/bin/touch "$LEASE_TEST_RELEASE"
wait "$LEASE_HOLDER_PID"
LEASE_HOLDER_PID=""
/usr/bin/python3 -I - "$FIXTURE/bin/.kist-deployment.lock" free <<'PY'
import fcntl,os,sys
path,expectation=sys.argv[1:]
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
try:
    try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: blocked=True
    else: blocked=False
finally:
    os.close(fd)
raise SystemExit(0 if blocked==(expectation=="blocked") else 1)
PY

# The launcher owns its flock descriptor directly. Losing that descriptor after validation is
# fail-closed, and unsafe named lock identities are rejected before any release mutation.
expect_reject dashboard-parent-lease-loss /usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_DASHBOARD_TEST_CLOSE_DEPLOYMENT_LEASE_AFTER_VALIDATION=1 \
  "$FIXTURE/bin/kist-dashboard" --provenance-validate
/usr/bin/grep -q 'deployment lease descriptor is not held by this process' \
  "$TMP/reject-dashboard-parent-lease-loss.err"
LOCK_PATH="$FIXTURE/bin/.kist-deployment.lock"
/bin/mv "$LOCK_PATH" "$TMP/held-deployment-lock"
/bin/ln -s "$TMP/held-deployment-lock" "$LOCK_PATH"
expect_reject symlink-deployment-lock "$FIXTURE/bin/kist-rebuild" --release-status
/bin/rm -f "$LOCK_PATH"
/bin/mv "$TMP/held-deployment-lock" "$LOCK_PATH"
/bin/ln "$LOCK_PATH" "$TMP/deployment-lock-hardlink"
expect_reject hardlinked-deployment-lock "$FIXTURE/bin/kist-dashboard" --provenance-validate
/bin/rm -f "$TMP/deployment-lock-hardlink"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

# The dashboard is inside the closure, so its evaluator cannot be allowed to attest only to itself.
# A replacement that replays the previously valid projection must still fail before it is executed.
/bin/cp "$FIXTURE/bin/kist-dashboard" "$TMP/dashboard-before-self-attestation"
"$FIXTURE/bin/kist-dashboard" --provenance-evaluate \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  > "$TMP/replayed-dashboard-closure"
{
  printf '#!/bin/sh\n'
  printf '/bin/cat %s\n' "$TMP/replayed-dashboard-closure"
} > "$FIXTURE/bin/kist-dashboard"
/bin/chmod 755 "$FIXTURE/bin/kist-dashboard"
expect_reject self-attesting-dashboard "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/cp "$TMP/dashboard-before-self-attestation" "$FIXTURE/bin/kist-dashboard"
/bin/chmod 755 "$FIXTURE/bin/kist-dashboard"
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null
/bin/ln "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist-current.alias"
expect_reject hardlinked-installed-payload "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/rm -f "$FIXTURE/bin/kist-current.alias"
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null

# The safe launcher binds selection to the installed manifest identity.  A stale identity must
# fail under the exclusive lease before repository selection or compilation begins.
expect_reject stale-safe-selection /usr/bin/env MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --expect-installed-manifest-sha256 \
  0000000000000000000000000000000000000000000000000000000000000000
/usr/bin/grep -q 'installed deployment changed after selection' \
  "$TMP/reject-stale-safe-selection.err"

# CWD is intentionally a repository that passes the old shape heuristic.  With deployed
# provenance unavailable and no explicit MYTHOS_REPO, it must not be selected implicitly.
/bin/mv "$FIXTURE/bin/kist-current.manifest" "$TMP/held-manifest"
set +e
(
  cd "$FIXTURE/project"
  /usr/bin/env -u MYTHOS_REPO "$FIXTURE/bin/kist-rebuild" --force --skip-suite
) >"$TMP/reject-wrong-pwd.out" 2>"$TMP/reject-wrong-pwd.err"
WRONG_PWD_STATUS=$?
set -e
/bin/mv "$TMP/held-manifest" "$FIXTURE/bin/kist-current.manifest"
[[ "$WRONG_PWD_STATUS" -ne 0 ]]
/usr/bin/grep -q 'no canonical Kist repo selected' "$TMP/reject-wrong-pwd.err"

expect_reject wrong-archive "$FIXTURE/bin/kist-rebuild" --release-archive --confirm \
  0000000000000000000000000000000000000000000000000000000000000000
# Matching names in the shared system temp directory are outside this installation's private
# cleanup namespace. Even an unsafe same-host decoy must be ignored and survive exclusive recovery.
GLOBAL_SNAPSHOT_DECOY=$(/usr/bin/mktemp -d /private/tmp/kist-source-snapshot.XXXXXX)
/bin/chmod 777 "$GLOBAL_SNAPSHOT_DECOY"
printf 'foreign namespace decoy\n' > "$GLOBAL_SNAPSHOT_DECOY/source.swift"
A_ARCHIVE=$("$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID")
[[ $(printf '%s' "$A_ARCHIVE" | json_value created) = True ]]
[[ -f "$GLOBAL_SNAPSHOT_DECOY/source.swift" ]]
/bin/rm -rf "$GLOBAL_SNAPSHOT_DECOY"
GLOBAL_SNAPSHOT_DECOY=""
ORPHAN_STAGE="$FIXTURE/bin/.kist-rollback-stage.00000000000000000000000000000000"
printf 'orphan rollback stage\n' > "$ORPHAN_STAGE"
/bin/chmod 600 "$ORPHAN_STAGE"
ARCHIVE_STAGE="$FIXTURE/.kist/release-registry/releases/.release-staging.00000000000000000000000000000000"
/bin/mkdir -m 700 "$ARCHIVE_STAGE"
/bin/mkdir -m 700 "$ARCHIVE_STAGE/files"
printf 'partial archive\n' > "$ARCHIVE_STAGE/files/kist"
/bin/chmod 755 "$ARCHIVE_STAGE/files/kist"
A_REPEAT=$("$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID")
[[ $(printf '%s' "$A_REPEAT" | json_value created) = False ]]
[[ ! -e "$ORPHAN_STAGE" && ! -e "$ARCHIVE_STAGE" ]]

# A SIGKILL before transaction begin can leave only exact mktemp-reserved staging names, and a
# killed build can leave a private source snapshot. The next exclusive recovery removes every
# exact owner-private shape without following a snapshot symlink or widening the deletion boundary.
STALE_PARENT="$FIXTURE/.kist-rebuild-private-tmp"
/bin/mkdir -p "$STALE_PARENT"
/bin/chmod 700 "$STALE_PARENT"
STALE_SNAPSHOT="$STALE_PARENT/kist-source-snapshot.A1b2C3"
/bin/mkdir -m 700 "$STALE_SNAPSHOT"
/bin/mkdir -m 700 "$STALE_SNAPSHOT/nested"
/bin/mkdir -m 700 "$STALE_SNAPSHOT/nested/read-only-child"
printf 'stale source bytes\n' > "$STALE_SNAPSHOT/nested/read-only-child/source.swift"
/bin/chmod 600 "$STALE_SNAPSHOT/nested/read-only-child/source.swift"
/bin/chmod 550 "$STALE_SNAPSHOT/nested/read-only-child"
/bin/chmod 555 "$STALE_SNAPSHOT/nested"
[[ $(/usr/bin/stat -f '%Lp' "$STALE_SNAPSHOT/nested") = 555 ]]
[[ $(/usr/bin/stat -f '%Lp' "$STALE_SNAPSHOT/nested/read-only-child") = 550 ]]
/usr/bin/mkfifo "$STALE_SNAPSHOT/compiler.fifo"
STALE_OUTSIDE="$TMP/stale-snapshot-outside"
printf 'must survive\n' > "$STALE_OUTSIDE"
/bin/ln -s "$STALE_OUTSIDE" "$STALE_SNAPSHOT/outside-link"
printf 'stale suite log\n' > "$STALE_PARENT/kist-rebuild-suite.Z9y8X7"
/bin/chmod 600 "$STALE_PARENT/kist-rebuild-suite.Z9y8X7"
RESERVED_STAGE_PREFIXES=(
  .kist-current.new .kist.wrapper .kist-dashboard .kist-rebuild .kist-safe-rebuild
  .kist-current.manifest .kist-build .kist-current.provenance .kist-status
  .kist-notary-archive .kist-notary-result .kist-current.manifest.final
  .kist-current.provenance.final .kist-current.projection.final
)
for prefix in "${RESERVED_STAGE_PREFIXES[@]}"; do
  printf 'stale stage\n' > "$FIXTURE/bin/${prefix}.A1b2C3"
  /bin/chmod 600 "$FIXTURE/bin/${prefix}.A1b2C3"
done
NEAR_MISS="$FIXTURE/bin/.kist-status.A1b2C"
printf 'not reserved\n' > "$NEAR_MISS"
/bin/chmod 600 "$NEAR_MISS"
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$STALE_SNAPSHOT" && ! -e "$STALE_PARENT/kist-rebuild-suite.Z9y8X7" ]]
[[ -f "$STALE_OUTSIDE" && -f "$NEAR_MISS" ]]
for prefix in "${RESERVED_STAGE_PREFIXES[@]}"; do
  [[ ! -e "$FIXTURE/bin/${prefix}.A1b2C3" ]]
done

# The source/HEAD/branch CAS is repeated while the promoted transaction is still reversible. A
# deterministic post-activation write to an ordinary tracked source must reject and restore the
# exact pre-image rather than committing a manifest for the earlier snapshot.
AFTER_ACTIVATION_HOOK="$TMP/after-activation-churn"
# shellcheck disable=SC2016 # $1 belongs to the generated hook, not this fixture shell.
printf '%s\n' \
  '#!/bin/sh' \
  '/usr/bin/python3 -I -c '"'"'import os; os.close(9)'"'"' 2>/dev/null && exit 82 || :' \
  'printf "%s\n" "after activation" >> "$1/fixture.txt"' \
  > "$AFTER_ACTIVATION_HOOK"
/bin/chmod 700 "$AFTER_ACTIVATION_HOOK"
/bin/cp "$FIXTURE/project/fixture.txt" "$TMP/fixture-before-after-activation"
set +e
/usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK="$AFTER_ACTIVATION_HOOK" \
  MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --skip-suite \
  >"$TMP/after-activation.out" 2>"$TMP/after-activation.err"
AFTER_ACTIVATION_STATUS=$?
set -e
[[ "$AFTER_ACTIVATION_STATUS" -ne 0 ]]
/usr/bin/grep -q 'changed after activation; rolling back' "$TMP/after-activation.err"
/bin/mv "$TMP/fixture-before-after-activation" "$FIXTURE/project/fixture.txt"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"
[[ -L "$FIXTURE/project/.build/release" ]]
[[ $(/usr/bin/readlink "$FIXTURE/project/.build/release") = arm64-apple-macosx/release ]]
/usr/bin/grep -q '^# SwiftPM release sentinel$' \
  "$FIXTURE/project/.build/arm64-apple-macosx/release/kist"
RETAINED_UNSIGNED_PATHS=("$FIXTURE/project/.build/.kist-provenance"/*)
[[ "${#RETAINED_UNSIGNED_PATHS[@]}" -eq 1 ]]
RETAINED_UNSIGNED_HASH=$(/usr/bin/basename "${RETAINED_UNSIGNED_PATHS[0]}")
[[ "$RETAINED_UNSIGNED_HASH" =~ ^[a-f0-9]{64}$ ]]
[[ -x "${RETAINED_UNSIGNED_PATHS[0]}" ]]
[[ $("/usr/bin/env" KIST_REBUILD_TESTING=1 \
  "$FIXTURE/bin/kist-rebuild" --test-hash-retained-unsigned-artifact \
  "$FIXTURE/project" "$RETAINED_UNSIGNED_HASH") = "$RETAINED_UNSIGNED_HASH" ]]
if compgen -G "$STALE_PARENT/kist-source-snapshot.??????" >/dev/null; then
  printf 'private source snapshot survived rejected after-activation churn\n' >&2
  exit 1
fi

# Semantic evidence validation is part of the still-reversible promotion.  The hook changes the
# canonical pilot bundle and updates its manifest digest, so byte/digest structure remains coherent
# while the bundle's product version no longer matches the manifest. The exclusive validator must
# reject that semantic mismatch and restore the exact installed pre-image.
SEMANTIC_EVIDENCE_HOOK="$TMP/after-activation-semantic-evidence"
printf '%s\n' \
  '#!/usr/bin/python3' \
  'from pathlib import Path' \
  'import hashlib,json,os' \
  'bindir=Path(os.environ["HOME"])/"bin"' \
  'evidence=bindir/"kist-current.provenance.json"' \
  'value=json.loads(evidence.read_text())' \
  'value["product_version"]="0.0.0-semantic-tamper"' \
  'raw=(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode()' \
  'evidence.write_bytes(raw)' \
  'manifest=bindir/"kist-current.manifest"' \
  'lines=[]' \
  'for line in manifest.read_text().splitlines(True):' \
  '    if line.startswith("deployment-evidence-sha256: "): line="deployment-evidence-sha256: "+hashlib.sha256(raw).hexdigest()+"\n"' \
  '    lines.append(line)' \
  'manifest.write_text("".join(lines))' \
  > "$SEMANTIC_EVIDENCE_HOOK"
/bin/chmod 700 "$SEMANTIC_EVIDENCE_HOOK"
/usr/bin/shasum -a 256 \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  "$FIXTURE/bin/kist-current.manifest" "$FIXTURE/bin/.kist-build" \
  "$FIXTURE/bin/kist-current.provenance.json" > "$TMP/semantic-preimage"
set +e
/usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK="$SEMANTIC_EVIDENCE_HOOK" \
  MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --skip-suite \
  >"$TMP/semantic-evidence.out" 2>"$TMP/semantic-evidence.err"
SEMANTIC_EVIDENCE_STATUS=$?
set -e
[[ "$SEMANTIC_EVIDENCE_STATUS" -ne 0 ]]
/usr/bin/grep -q 'post-promotion evidence, signing, or artifact provenance validation failed' \
  "$TMP/semantic-evidence.err"
/usr/bin/shasum -a 256 \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  "$FIXTURE/bin/kist-current.manifest" "$FIXTURE/bin/.kist-build" \
  "$FIXTURE/bin/kist-current.provenance.json" > "$TMP/semantic-restored"
/usr/bin/cmp -s "$TMP/semantic-preimage" "$TMP/semantic-restored"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

# Losing the parent-owned exclusive descriptor after activation lets an overlapping shared reader
# acquire the file but reject the pending journal. The original shell detects its missing
# descriptor, reacquires exclusive ownership, and rolls the reversible transaction back.
LEASE_LOSS_HOOK="$TMP/after-activation-lease-loss"
# shellcheck disable=SC2016 # HOME belongs to the generated hook.
printf '%s\n' \
  '#!/bin/sh' \
  '/usr/bin/python3 -I -c '"'"'import os; os.close(9)'"'"' 2>/dev/null && exit 82 || :' \
  'if "$HOME/bin/kist-rebuild" --release-status > "$HOME/lease-overlap.out" 2> "$HOME/lease-overlap.err"; then exit 81; fi' \
  'printf "%s\\n" rejected > "$HOME/lease-overlap.marker"' \
  > "$LEASE_LOSS_HOOK"
/bin/chmod 700 "$LEASE_LOSS_HOOK"
/usr/bin/shasum -a 256 \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  "$FIXTURE/bin/kist-current.manifest" "$FIXTURE/bin/.kist-build" \
  "$FIXTURE/bin/kist-current.provenance.json" > "$TMP/lease-loss-preimage"
set +e
/usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_REBUILD_TEST_CLOSE_DEPLOYMENT_LEASE_AFTER_ACTIVATION=1 \
  KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK="$LEASE_LOSS_HOOK" \
  MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --skip-suite \
  >"$TMP/lease-loss.out" 2>"$TMP/lease-loss.err"
LEASE_LOSS_STATUS=$?
set -e
[[ "$LEASE_LOSS_STATUS" -ne 0 && -f "$FIXTURE/lease-overlap.marker" ]]
/usr/bin/grep -q 'deployment lease descriptor is not held by this process' "$TMP/lease-loss.err"
/usr/bin/grep -q 'deployment transaction requires exclusive recovery' \
  "$FIXTURE/lease-overlap.err"
/usr/bin/shasum -a 256 \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  "$FIXTURE/bin/kist-current.manifest" "$FIXTURE/bin/.kist-build" \
  "$FIXTURE/bin/kist-current.provenance.json" > "$TMP/lease-loss-restored"
/usr/bin/cmp -s "$TMP/lease-loss-preimage" "$TMP/lease-loss-restored"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
if compgen -G "$FIXTURE/bin/.kist-rollback-stage.*" >/dev/null \
   || compgen -G "$STALE_PARENT/kist-source-snapshot.??????" >/dev/null; then
  printf 'lease-loss rollback left transaction staging behind\n' >&2
  exit 1
fi
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

install_release "1.0.0-beta" "$FIXTURE/fixture-pass" "2026-07-24 11:00:00" beta
B_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
[[ "$B_ID" =~ ^[a-f0-9]{64}$ && "$B_ID" != "$A_ID" ]]
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$B_ID" >/dev/null

# V3 archives only transactionally restorable payloads. Mutable runtime/cortex state remains an
# operational trust-walk: content changes do not rewrite the release ID, unsafe modes still fail.
printf '# runtime changed independently\n' >> "$FIXTURE/.kist/scripts/kist_runtime.py"
printf '# cortex changed independently\n' >> "$FIXTURE/.kist/cortex/live/app.py"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$B_ID" ]]
"$FIXTURE/bin/kist-dashboard" --provenance-validate
/bin/chmod 777 "$FIXTURE/.kist/scripts/kist_runtime.py"
expect_reject unsafe-runtime "$FIXTURE/bin/kist-dashboard" --provenance-validate
/bin/chmod 755 "$FIXTURE/.kist/scripts/kist_runtime.py"

# A coherent target whose binary fails --help must activate, fail the post-activation smoke gate,
# and restore the exact pre-image through the existing durable transaction.
install_release "1.0.0-fail" "$FIXTURE/fixture-fail" "2026-07-24 12:00:00" fail
FAIL_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$FAIL_ID" >/dev/null
install_release "1.0.0-beta" "$FIXTURE/fixture-pass" "2026-07-24 11:00:00" beta
FAIL_PLAN="$TMP/fail-plan.json"
FAIL_PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$FAIL_ID" --out "$FAIL_PLAN")
FAIL_PLAN_DIGEST=$(printf '%s' "$FAIL_PLAN_OUT" | json_value plan_digest)
expect_reject post-activation-smoke "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$FAIL_PLAN" --confirm "$FAIL_PLAN_DIGEST"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$B_ID" ]]
grep -q '^# fixture-release: beta$' "$FIXTURE/bin/kist-safe-rebuild.sh"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]

# Canonical plan bytes, full plan confirmation, target record bytes, and current-state CAS all bind.
PLAN="$TMP/alpha-plan.json"
PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$A_ID" --out "$PLAN")
PLAN_DIGEST=$(printf '%s' "$PLAN_OUT" | json_value plan_digest)
/bin/cp "$PLAN" "$TMP/tampered-plan.json"
printf ' ' >> "$TMP/tampered-plan.json"
expect_reject tampered-plan "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$TMP/tampered-plan.json" --confirm "$PLAN_DIGEST"
expect_reject wrong-plan-confirm "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$PLAN" --confirm 0000000000000000000000000000000000000000000000000000000000000000
install_release "1.0.0-gamma" "$FIXTURE/fixture-pass" "2026-07-24 13:00:00" gamma
expect_reject stale-current "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$PLAN" --confirm "$PLAN_DIGEST"
install_release "1.0.0-beta" "$FIXTURE/fixture-pass" "2026-07-24 11:00:00" beta

"$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$PLAN" --confirm "$PLAN_DIGEST" >"$TMP/apply.out"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '1.0.0-alpha' "$FIXTURE/bin/kist-current.manifest"
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"

# A process killed after activation leaves a durable journal. Shared readers fail closed; the next
# exclusive release operation recovers alpha before doing any registry work.
INTERRUPT_PLAN="$TMP/interrupt-plan.json"
INTERRUPT_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$B_ID" --out "$INTERRUPT_PLAN")
INTERRUPT_DIGEST=$(printf '%s' "$INTERRUPT_OUT" | json_value plan_digest)
set +e
KIST_REBUILD_TESTING=1 KIST_ROLLBACK_TEST_INTERRUPT_AFTER=activation-sigkill \
  "$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$INTERRUPT_PLAN" \
  --confirm "$INTERRUPT_DIGEST" >"$TMP/interrupt.out" 2>"$TMP/interrupt.err"
INTERRUPT_STATUS=$?
set -e
[[ "$INTERRUPT_STATUS" -ne 0 && -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
expect_reject pending-reader "$FIXTURE/bin/kist-rebuild" --release-status
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"

# Recovery remains compatible with a pending seven-target journal written by the previous gate.
/usr/bin/python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import json,os,shutil,sys
home=Path(sys.argv[1]); bindir=home/"bin"; token="1"*32
targets=["kist-current","kist","kist-dashboard","kist-rebuild",
         "kist-current.manifest",".kist-build","kist-current.provenance.json"]
backup=bindir/f".kist-rebuild-backup.{token}"; backup.mkdir(mode=0o700)
for name in targets:
    source=bindir/name; target=backup/name
    shutil.copyfile(source,target); os.chmod(target,source.stat().st_mode&0o777)
journal={"schema":1,"token":token,"phase":"active","backup":backup.name,"targets":targets,
         "present":{name:True for name in targets},"installed":targets}
(bindir/".kist-rebuild-journal").write_text(
    json.dumps(journal,sort_keys=True,separators=(",",":"))+"\n")
os.chmod(bindir/".kist-rebuild-journal",0o600)
(bindir/"kist").write_text("#!/bin/sh\nexit 97\n"); os.chmod(bindir/"kist",0o755)
PY
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"

# Recovery accepts only the exact private temp shape that copy_stable can leave in a preparing
# backup. A crash or ENOSPC before the temp rename must not wedge every future deployment.
/usr/bin/python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import json,os,sys
home=Path(sys.argv[1]); bindir=home/"bin"; token="2"*32
targets=["kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh",
         "kist-current.manifest",".kist-build","kist-current.provenance.json"]
backup=bindir/f".kist-rebuild-backup.{token}"; backup.mkdir(mode=0o700)
partial=backup/("kist-current.new."+"3"*24)
partial.write_bytes(b"partial backup copy"); partial.chmod(0o600)
journal={"schema":1,"token":token,"phase":"preparing","backup":backup.name,
         "targets":targets,"present":{name:True for name in targets},"installed":[]}
(bindir/".kist-rebuild-journal").write_text(
    json.dumps(journal,sort_keys=True,separators=(",",":"))+"\n")
os.chmod(bindir/".kist-rebuild-journal",0o600)
PY
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ ! -e "$FIXTURE/bin/.kist-rebuild-backup.$(printf '2%.0s' {1..32})" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

# Once restored targets and their directory entry are durable, rolled-back is a terminal journal
# phase. Recovery must tolerate a kill after any subset of backup files has already been deleted.
/usr/bin/python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import json,os,shutil,sys
home=Path(sys.argv[1]); bindir=home/"bin"; token="4"*32
targets=["kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh",
         "kist-current.manifest",".kist-build","kist-current.provenance.json"]
backup=bindir/f".kist-rebuild-backup.{token}"; backup.mkdir(mode=0o700)
shutil.copyfile(bindir/"kist",backup/"kist"); os.chmod(backup/"kist",0o755)
journal={"schema":1,"token":token,"phase":"rolled-back","backup":backup.name,
         "targets":targets,"present":{name:True for name in targets},"installed":targets}
(bindir/".kist-rebuild-journal").write_text(
    json.dumps(journal,sort_keys=True,separators=(",",":"))+"\n")
os.chmod(bindir/".kist-rebuild-journal",0o600)
PY
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ ! -e "$FIXTURE/bin/.kist-rebuild-backup.$(printf '4%.0s' {1..32})" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

# A seven-file release record created by the previous release gate remains listable and
# rollback-capable.  Its manifest ignores the installed safe helper; returning to v3 restores the
# helper as the eighth transactional payload.
install_release "0.9.0-legacy" "$FIXTURE/fixture-pass" "2026-07-23 09:00:00" legacy legacy
LEGACY_ID=$(archive_legacy_fixture)
[[ "$LEGACY_ID" =~ ^[a-f0-9]{64}$ && "$LEGACY_ID" != "$A_ID" ]]
install_release "1.0.0-alpha" "$FIXTURE/fixture-pass" "2026-07-24 10:00:00" alpha
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
LEGACY_PLAN="$TMP/legacy-plan.json"
LEGACY_PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$LEGACY_ID" --out "$LEGACY_PLAN")
LEGACY_PLAN_DIGEST=$(printf '%s' "$LEGACY_PLAN_OUT" | json_value plan_digest)
[[ $(printf '%s' "$LEGACY_PLAN_OUT" | json_value target_rollback_semantics) = \
   best-effort-legacy-non-self-contained ]]
"$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$LEGACY_PLAN" \
  --confirm "$LEGACY_PLAN_DIGEST" >/dev/null
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$LEGACY_ID" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value rollback_semantics) = \
   best-effort-legacy-non-self-contained ]]
/usr/bin/grep -q '^dashboard-runtime-sha256:' "$FIXTURE/bin/kist-current.manifest"
if /usr/bin/grep -q '^safe-rebuild-sha256:' "$FIXTURE/bin/kist-current.manifest"; then
  printf 'legacy rollback unexpectedly retained a v3 manifest field\n' >&2
  exit 1
fi
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"
RETURN_PLAN="$TMP/return-alpha-plan.json"
RETURN_PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$A_ID" --out "$RETURN_PLAN")
RETURN_PLAN_DIGEST=$(printf '%s' "$RETURN_PLAN_OUT" | json_value plan_digest)
"$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$RETURN_PLAN" \
  --confirm "$RETURN_PLAN_DIGEST" >/dev/null
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '^safe-rebuild-sha256:' "$FIXTURE/bin/kist-current.manifest"
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"

# A legacy record did not archive runtime/cortex. Detect an incompatible operational closure before
# replacing any installed target, and leave the exact current v3 release active.
/bin/cp "$FIXTURE/.kist/scripts/kist_runtime.py" "$TMP/runtime-before-legacy-dry-check"
printf '# incompatible legacy runtime\n' >> "$FIXTURE/.kist/scripts/kist_runtime.py"
LEGACY_STALE_PLAN="$TMP/legacy-stale-plan.json"
LEGACY_STALE_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$LEGACY_ID" \
  --out "$LEGACY_STALE_PLAN")
LEGACY_STALE_DIGEST=$(printf '%s' "$LEGACY_STALE_OUT" | json_value plan_digest)
expect_reject legacy-operational-closure "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$LEGACY_STALE_PLAN" --confirm "$LEGACY_STALE_DIGEST"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
/bin/mv "$TMP/runtime-before-legacy-dry-check" "$FIXTURE/.kist/scripts/kist_runtime.py"
/bin/chmod 755 "$FIXTURE/.kist/scripts/kist_runtime.py"
[[ $(/usr/bin/shasum -a 256 "$FIXTURE/project/.kist/usage.jsonl" \
  | /usr/bin/awk '{print $1}') = "$RUNTIME_USAGE_HASH" ]]
[[ -f "$FIXTURE/project/.kist/runs/1785376007-155a334c/events.jsonl" ]]
[[ -f "$FIXTURE/project/.kist/runs/1785376008-255a334c/events.jsonl" ]]

LIST=$("$FIXTURE/bin/kist-rebuild" --release-list)
[[ $(printf '%s' "$LIST" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)["releases"]))') = 4 ]]
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null

printf 'PASS kist deployment protocol: v3 and legacy rollback, state separation, CAS selection/plans, old-journal recovery, SIGKILL recovery\n'
