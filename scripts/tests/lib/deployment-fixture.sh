#!/usr/bin/env bash
# Disposable deployment fixture shared by protocol and resource regressions.
REBUILD_SOURCE=${KIST_REBUILD_UNDER_TEST:-$REPO_ROOT/scripts/kist-rebuild}
DASHBOARD_SOURCE=${KIST_DASHBOARD_UNDER_TEST:-$REPO_ROOT/scripts/kist-dashboard}
SAFE_REBUILD_SOURCE=${KIST_SAFE_REBUILD_UNDER_TEST:-$REPO_ROOT/scripts/kist-safe-rebuild.sh}
[[ -x "$REBUILD_SOURCE" && -x "$DASHBOARD_SOURCE" && -x "$SAFE_REBUILD_SOURCE" ]] \
  || { printf 'missing rebuild/dashboard/safe-rebuild launchers\n' >&2; exit 1; }
TMP=$(/usr/bin/mktemp -d "${HOME}/.kist-release-registry-test.XXXXXX")
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
    'let package = Package(name: "AgentCore", products: ['
    '.executable(name: "kist", targets: ["Kist"])], targets: ['
    '.target(name: "AgentCore", resources: [.copy("Skills/builtin")]),'
    '.executableTarget(name: "Kist", dependencies: ["AgentCore"])])\n')
(project/"Sources/Kist/KistRunner.swift").write_text(
    'import Foundation\n'
    'if CommandLine.arguments.contains("--version") { print("kist 9.9.9-test.1") }\n')
(project/"Sources/AgentCore/CaptainOrchestrator.swift").write_text("// fixture\n")
(project/"Tests/KistTests/KistOptionsTests.swift").write_text("// fixture\n")
(project/"scripts/kist-rebuild").write_text("#!/bin/sh\n# tracked fixture source\n")
for skill in ("code-investigation","web-research"):
    path=project/"Sources/AgentCore/Skills/builtin"/skill/"SKILL.md"
    path.parent.mkdir(parents=True); path.write_text("source resource: "+skill+"\n")
    path.chmod(0o644)
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
  local version=$1 binary_source=$2 deployed=$3 source_tag=$4 closure_kind=${5:-v4}
  /bin/cp "$binary_source" "$FIXTURE/bin/kist-current"
  /bin/chmod 755 "$FIXTURE/bin/kist-current"
  /bin/cp "$SAFE_REBUILD_SOURCE" "$FIXTURE/bin/kist-safe-rebuild.sh"
  printf '\n# fixture-release: %s\n' "$source_tag" >> "$FIXTURE/bin/kist-safe-rebuild.sh"
  /bin/chmod 755 "$FIXTURE/bin/kist-safe-rebuild.sh"
  if [[ "$closure_kind" == v4 ]]; then
    local skill
    for skill in code-investigation web-research; do
      /bin/mkdir -p "$FIXTURE/bin/AgentCore_AgentCore.bundle/builtin/$skill"
      printf 'resource %s: %s\n' "$skill" "$source_tag" \
        > "$FIXTURE/bin/AgentCore_AgentCore.bundle/builtin/$skill/SKILL.md"
      /bin/chmod 644 "$FIXTURE/bin/AgentCore_AgentCore.bundle/builtin/$skill/SKILL.md"
    done
    "$FIXTURE/bin/kist-dashboard" --provenance-evaluate \
      "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
      "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
      "$FIXTURE/bin/AgentCore_AgentCore.bundle/builtin/code-investigation/SKILL.md" \
      "$FIXTURE/bin/AgentCore_AgentCore.bundle/builtin/web-research/SKILL.md" > "$TMP/closure"
  elif [[ "$closure_kind" == v3 ]]; then
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
    fields["dashboard-runtime-sha256"]=closure["dashboard-runtime-sha256"]
    fields["dashboard-cortex-sha256"]=closure["dashboard-cortex-sha256"]
    fields["dashboard-cortex-count"]=closure["dashboard-cortex-count"]
    payload_identities=["safe-rebuild-sha256","dashboard-runtime-sha256",
                        "dashboard-cortex-sha256","dashboard-cortex-count"]
else:
    fields["dashboard-runtime-sha256"]=closure["dashboard-runtime-sha256"]
    payload_identities=["dashboard-runtime-sha256"]
for key in ("resource-code-investigation-sha256","resource-web-research-sha256"):
    if key in closure:
        fields[key]=closure[key]; payload_identities.append(key)
order=["schema","stamp","deployed","worktree","branch","commit","remote-origin-sha256","repository-id",
       "source-dirty","source-state-sha256","binary-sha256","wrapper-sha256",
       "dashboard-launcher-sha256","rebuild-sha256",*payload_identities,
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
projection_value() {
  /usr/bin/python3 -c 'from pathlib import Path; import sys; values=dict(line.split("=",1) for line in Path(sys.argv[1]).read_text().splitlines()); print(values[sys.argv[2]])' "$1" "$2"
}
expect_reject() {
  local label=$1
  shift
  if "$@" >"$TMP/reject-$label.out" 2>"$TMP/reject-$label.err"; then
    printf 'invalid release operation unexpectedly accepted: %s\n' "$label" >&2
    exit 1
  else
    REJECTION_STATUS=$?
  fi
}

# Materialize an exact registry shape produced by a previous release gate. New code deliberately
# refuses fresh unbound archives, so compatibility is exercised with authentic old records rather
# than weakening production archive admission.
archive_compat_fixture() {
  local shape=${1:-legacy}
  /usr/bin/python3 - "$FIXTURE" "$shape" <<'PY'
from pathlib import Path
import datetime,hashlib,json,os,shutil,sys,time

home=Path(sys.argv[1]); shape=sys.argv[2]; bindir=home/"bin"
releases=home/".kist/release-registry/releases"
legacy=["kist-current","kist","kist-dashboard","kist-rebuild",
        "kist-current.manifest",".kist-build","kist-current.provenance.json"]
v3=["kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh",
    "kist-current.manifest",".kist-build","kist-current.provenance.json"]
if shape not in {"legacy","v3"}: raise SystemExit(1)
targets=v3 if shape=="v3" else legacy
executables={"kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh"}

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
