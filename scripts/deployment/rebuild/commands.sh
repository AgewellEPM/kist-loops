trap 'release_deployment_lease' 0
trap 'exit 130' 2
trap 'exit 143' 15

if [ "${1-}" = "--test-hold-deployment-lease" ]; then
  [ "${KIST_REBUILD_TESTING-}" = 1 ] && [ "$INSTALL_HOME" != /Users/lukekist ] \
    || die "deployment lease test hooks are forbidden for production"
  [ "$#" -eq 3 ] || die "--test-hold-deployment-lease requires ABSOLUTE_READY ABSOLUTE_RELEASE"
  case "$2:$3" in /*:/*) ;; *) die "deployment lease test paths must be absolute" ;; esac
  acquire_deployment_lease exclusive
  python_clean - "$2" "$3" <<'PY' || die "deployment lease test coordination failed"
import errno,os,stat,sys,time
ready,release=sys.argv[1:]; uid=os.geteuid()
try:
    os.fstat(9)
except OSError as error:
    if error.errno!=errno.EBADF: raise
else:
    raise SystemExit(1)
for path in (ready,release):
    parent=os.path.dirname(path); leaf=os.path.basename(path)
    if not leaf or "/" in leaf or os.path.realpath(parent)!=parent:
        raise SystemExit(1)
    value=os.lstat(parent)
    if not stat.S_ISDIR(value.st_mode) or value.st_uid!=uid or value.st_mode&0o022:
        raise SystemExit(1)
fd=os.open(ready,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
try:
    os.write(fd,b"shell-owned-exclusive-lease\n"); os.fsync(fd)
finally:
    os.close(fd)
deadline=time.monotonic()+20.0
while time.monotonic()<deadline:
    try: value=os.lstat(release)
    except FileNotFoundError:
        time.sleep(.02); continue
    if (not stat.S_ISREG(value.st_mode) or value.st_uid!=uid or value.st_nlink!=1
            or value.st_mode&0o077):
        raise SystemExit(1)
    raise SystemExit(0)
raise SystemExit(75)
PY
  require_deployment_lease exclusive
  release_deployment_lease
  exit 0
fi

if [ "${1-}" = "--release-status" ]; then
  [ "$#" -eq 1 ] || die "--release-status takes no values"
  acquire_deployment_lease shared
  transaction_control check-clean || die "a deployment transaction requires exclusive recovery"
  deployed_repo >/dev/null || die "installed deployment is not coherent"
  validate_installed_dashboard || die "dashboard launcher/runtime ownership, mode, or ancestry is untrusted"
  "$DASHBOARD_LAUNCHER" --provenance-validate 9>&- \
    || die "dashboard artifact closure validation failed"
  release_registry_control status || die "cannot inspect the release registry"
  exit 0
fi

if [ "${1-}" = "--release-list" ]; then
  [ "$#" -eq 1 ] || die "--release-list takes no values"
  acquire_deployment_lease shared
  transaction_control check-clean || die "a deployment transaction requires exclusive recovery"
  deployed_repo >/dev/null || die "installed deployment is not coherent"
  validate_installed_dashboard || die "dashboard launcher/runtime ownership, mode, or ancestry is untrusted"
  "$DASHBOARD_LAUNCHER" --provenance-validate 9>&- \
    || die "dashboard artifact closure validation failed"
  release_registry_control list || die "cannot validate the release registry"
  exit 0
fi

if [ "${1-}" = "--release-archive" ]; then
  [ "$#" -eq 3 ] && [ "$2" = "--confirm" ] \
    || die "--release-archive requires --confirm CURRENT_RELEASE_ID"
  acquire_deployment_lease exclusive
  transaction_control recover || die "cannot recover the previous deployment transaction"
  validate_installed_provenance_exclusive \
    || die "installed deployment provenance, evidence, or signing state is not coherent"
  release_registry_control archive "$3" || die "cannot archive the current known-good release"
  exit 0
fi

if [ "${1-}" = "--rollback-plan" ]; then
  [ "$#" -eq 4 ] && [ "$3" = "--out" ] \
    || die "--rollback-plan requires TARGET_RELEASE_ID --out ABSOLUTE_NEW_PLAN"
  acquire_deployment_lease shared
  transaction_control check-clean || die "a deployment transaction requires exclusive recovery"
  deployed_repo >/dev/null || die "installed deployment is not coherent"
  validate_installed_dashboard || die "dashboard launcher/runtime ownership, mode, or ancestry is untrusted"
  "$DASHBOARD_LAUNCHER" --provenance-validate 9>&- \
    || die "dashboard artifact closure validation failed"
  release_registry_control plan "$2" "$4" || die "cannot create the rollback plan"
  exit 0
fi

if [ "${1-}" = "--rollback-apply" ]; then
  [ "$#" -eq 5 ] && [ "$2" = "--plan" ] && [ "$4" = "--confirm" ] \
    || die "--rollback-apply requires --plan ABSOLUTE_PLAN --confirm PLAN_DIGEST"
  ROLLBACK_PLAN=$3
  ROLLBACK_CONFIRM=$5
  acquire_deployment_lease exclusive
  transaction_control recover || die "cannot recover the previous deployment transaction"
  validate_installed_provenance_exclusive \
    || die "installed deployment provenance, evidence, or signing state is not coherent"
  ROLLBACK_TRANSACTION_ACTIVE=0
  TMP_ROLLBACK_BINARY=
  TMP_ROLLBACK_WRAPPER=
  TMP_ROLLBACK_DASHBOARD=
  TMP_ROLLBACK_REBUILD=
  TMP_ROLLBACK_SAFE_REBUILD=
  TMP_ROLLBACK_RESOURCE_CODE=
  TMP_ROLLBACK_RESOURCE_WEB=
  TMP_ROLLBACK_MANIFEST=
  TMP_ROLLBACK_STAMP=
  TMP_ROLLBACK_EVIDENCE=
  # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
  rollback_cleanup() {
    rollback_status=$?
    trap - 0 1 2 15
    if [ "$ROLLBACK_TRANSACTION_ACTIVE" -eq 1 ]; then
      if ensure_exclusive_recovery_lease; then
        transaction_control rollback || rollback_status=1
      else
        rollback_status=1
      fi
      ROLLBACK_TRANSACTION_ACTIVE=0
    fi
    for staged_path in "$TMP_ROLLBACK_BINARY" "$TMP_ROLLBACK_WRAPPER" "$TMP_ROLLBACK_DASHBOARD" \
      "$TMP_ROLLBACK_REBUILD" "$TMP_ROLLBACK_SAFE_REBUILD" "$TMP_ROLLBACK_MANIFEST" \
      "$TMP_ROLLBACK_STAMP" "$TMP_ROLLBACK_EVIDENCE" \
      "$TMP_ROLLBACK_RESOURCE_CODE" "$TMP_ROLLBACK_RESOURCE_WEB"; do
      [ -z "$staged_path" ] || /bin/rm -f "$staged_path"
    done
    release_deployment_lease || rollback_status=1
    exit "$rollback_status"
  }
  trap rollback_cleanup 0
  trap 'exit 130' 2
  trap 'exit 143' 15
  STAGE_OUTPUT=$(release_registry_control stage "$ROLLBACK_PLAN" "$ROLLBACK_CONFIRM") \
    || die "rollback plan, current deployment, or target archive did not validate"
  stage_value() {
    printf '%s\n' "$STAGE_OUTPUT" | /usr/bin/awk -F= -v key="$1" \
      '$1==key {if(seen++)exit 2;value=substr($0,length(key)+2)} END{if(seen!=1||value=="")exit 3;print value}'
  }
  ROLLBACK_TARGET=$(stage_value target-release-id) || die "rollback staging omitted target identity"
  TMP_ROLLBACK_BINARY=$(stage_value kist-current) || die "rollback staging omitted binary"
  TMP_ROLLBACK_WRAPPER=$(stage_value kist) || die "rollback staging omitted wrapper"
  TMP_ROLLBACK_DASHBOARD=$(stage_value kist-dashboard) || die "rollback staging omitted dashboard"
  TMP_ROLLBACK_REBUILD=$(stage_value kist-rebuild) || die "rollback staging omitted rebuild"
  TMP_ROLLBACK_SAFE_REBUILD=$(stage_value kist-safe-rebuild.sh 2>/dev/null || true)
  TMP_ROLLBACK_RESOURCE_CODE=$(stage_value kist-resource-code-investigation.md 2>/dev/null || true)
  TMP_ROLLBACK_RESOURCE_WEB=$(stage_value kist-resource-web-research.md 2>/dev/null || true)
  TMP_ROLLBACK_MANIFEST=$(stage_value kist-current.manifest) || die "rollback staging omitted manifest"
  TMP_ROLLBACK_STAMP=$(stage_value .kist-build) || die "rollback staging omitted stamp"
  TMP_ROLLBACK_EVIDENCE=$(stage_value kist-current.provenance.json) || die "rollback staging omitted evidence"
  if [ -n "$TMP_ROLLBACK_RESOURCE_CODE" ] && [ -n "$TMP_ROLLBACK_RESOURCE_WEB" ]; then
    ROLLBACK_DRY_KIND=v4
    ROLLBACK_DRY_CLOSURE=$("$DASHBOARD_LAUNCHER" --provenance-evaluate \
      "$TMP_ROLLBACK_BINARY" "$TMP_ROLLBACK_WRAPPER" "$TMP_ROLLBACK_DASHBOARD" \
      "$TMP_ROLLBACK_REBUILD" "$TMP_ROLLBACK_SAFE_REBUILD" \
      "$TMP_ROLLBACK_RESOURCE_CODE" "$TMP_ROLLBACK_RESOURCE_WEB" 9>&-) \
      || die "v4 rollback target resources cannot be evaluated"
  elif [ -n "$TMP_ROLLBACK_RESOURCE_CODE$TMP_ROLLBACK_RESOURCE_WEB" ]; then
    die "rollback staging omitted part of the resource inventory"
  elif [ -n "$TMP_ROLLBACK_SAFE_REBUILD" ]; then
    ROLLBACK_DRY_KIND=v3
    ROLLBACK_DRY_CLOSURE=$("$DASHBOARD_LAUNCHER" --provenance-evaluate \
      "$TMP_ROLLBACK_BINARY" "$TMP_ROLLBACK_WRAPPER" "$TMP_ROLLBACK_DASHBOARD" \
      "$TMP_ROLLBACK_REBUILD" "$TMP_ROLLBACK_SAFE_REBUILD" 9>&-) \
      || die "v3 rollback target cannot be evaluated against the current operational state"
  else
    ROLLBACK_DRY_KIND=v2
    ROLLBACK_DRY_CLOSURE=$("$DASHBOARD_LAUNCHER" --provenance-evaluate \
      "$TMP_ROLLBACK_BINARY" "$TMP_ROLLBACK_WRAPPER" "$TMP_ROLLBACK_DASHBOARD" \
      "$TMP_ROLLBACK_REBUILD" 9>&-) \
      || die "legacy rollback target is not compatible with the current mutable runtime/cortex"
  fi
  resource_python "$TMP_ROLLBACK_MANIFEST" "$ROLLBACK_DRY_CLOSURE" \
    "$ROLLBACK_DRY_KIND" <<'PY' \
    || die "rollback target artifact or operational closure does not match the current state"
import os,stat,sys
manifest_path,projection_text,kind=sys.argv[1:]
st=os.lstat(manifest_path)
if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.geteuid() or st.st_nlink!=1: raise SystemExit(1)
fields={}
for raw in open(manifest_path,encoding="utf-8"):
    key,separator,value=raw.rstrip("\n").partition(":")
    key=key.strip().lower(); value=value.strip()
    if not separator or not key or not value or key in fields: raise SystemExit(1)
    fields[key]=value
projection={}
for raw in projection_text.splitlines():
    key,separator,value=raw.partition("=")
    if not separator or not key or not value or key in projection: raise SystemExit(1)
    projection[key]=value
v2={"binary-sha256","wrapper-sha256","dashboard-launcher-sha256","rebuild-sha256",
    "dashboard-runtime-sha256","artifact-closure-sha256","artifact-closure-count"}
v3_legacy={"binary-sha256","wrapper-sha256","dashboard-launcher-sha256","rebuild-sha256",
           "safe-rebuild-sha256","artifact-closure-sha256","artifact-closure-count"}
operational={"dashboard-runtime-sha256","dashboard-cortex-sha256","dashboard-cortex-count"}
if kind=="v2":
    if set(projection)!=v2: raise SystemExit(1)
    required=v2
elif kind=="v4":
    required=v3_legacy|operational|set(RESOURCE_KEYS.values())
    if set(projection)!=required: raise SystemExit(1)
elif kind=="v3":
    if set(projection)!=v3_legacy|operational: raise SystemExit(1)
    present=operational&set(fields)
    if present and present!=operational: raise SystemExit(1)
    required=v3_legacy|(operational if present else set())
else:
    raise SystemExit(1)
if any(fields.get(key)!=projection[key] for key in required):
    raise SystemExit(1)
PY
  ROLLBACK_TRANSACTION_ACTIVE=1
  if [ "$ROLLBACK_DRY_KIND" = v4 ]; then
    ROLLBACK_TOKEN=$(transaction_control begin "$TMP_ROLLBACK_BINARY" "$TMP_ROLLBACK_WRAPPER" \
      "$TMP_ROLLBACK_DASHBOARD" "$TMP_ROLLBACK_REBUILD" "$TMP_ROLLBACK_SAFE_REBUILD" \
      "$TMP_ROLLBACK_MANIFEST" "$TMP_ROLLBACK_STAMP" "$TMP_ROLLBACK_EVIDENCE" \
      "$TMP_ROLLBACK_RESOURCE_CODE" "$TMP_ROLLBACK_RESOURCE_WEB") \
      || die "resource rollback transaction could not be started"
  elif [ -n "$TMP_ROLLBACK_SAFE_REBUILD" ]; then
    ROLLBACK_TOKEN=$(transaction_control begin "$TMP_ROLLBACK_BINARY" "$TMP_ROLLBACK_WRAPPER" \
      "$TMP_ROLLBACK_DASHBOARD" "$TMP_ROLLBACK_REBUILD" "$TMP_ROLLBACK_SAFE_REBUILD" \
      "$TMP_ROLLBACK_MANIFEST" "$TMP_ROLLBACK_STAMP" "$TMP_ROLLBACK_EVIDENCE") \
      || die "rollback transaction could not be started"
  else
    ROLLBACK_TOKEN=$(transaction_control begin "$TMP_ROLLBACK_BINARY" "$TMP_ROLLBACK_WRAPPER" \
      "$TMP_ROLLBACK_DASHBOARD" "$TMP_ROLLBACK_REBUILD" "$TMP_ROLLBACK_MANIFEST" \
      "$TMP_ROLLBACK_STAMP" "$TMP_ROLLBACK_EVIDENCE") \
      || die "legacy rollback transaction could not be started"
  fi
  [ -n "$ROLLBACK_TOKEN" ] || die "rollback transaction omitted its identity"
  if [ "${KIST_REBUILD_TESTING-}" = 1 ] && [ "${KIST_ROLLBACK_TEST_INTERRUPT_AFTER-}" = activation ]; then
    [ "$INSTALL_HOME" != /Users/lukekist ] || die "test interruption hooks are forbidden for production"
    /bin/kill -TERM "$$"
  elif [ "${KIST_REBUILD_TESTING-}" = 1 ] && [ "${KIST_ROLLBACK_TEST_INTERRUPT_AFTER-}" = activation-sigkill ]; then
    [ "$INSTALL_HOME" != /Users/lukekist ] || die "test interruption hooks are forbidden for production"
    /bin/kill -KILL "$$"
  fi
  require_deployment_lease exclusive
  validate_installed_provenance_exclusive \
    || die "restored deployment failed schema-4 provenance, evidence, or signing validation"
  "$INSTALL_HOME/bin/kist-current" --help 9>&- >/dev/null 2>&1 \
    || die "restored binary failed its post-rollback --help smoke check"
  require_deployment_lease exclusive
  transaction_control commit || die "rollback transaction could not be committed"
  ROLLBACK_TRANSACTION_ACTIVE=0
  trap - 0 1 2 15
  release_deployment_lease
  printf 'rollback committed -> %s\n' "$ROLLBACK_TARGET"
  exit 0
fi

if [ "${1-}" = "--validate-deployment" ]; then
  [ "$#" -eq 1 ] || die "--validate-deployment takes no values"
  acquire_deployment_lease shared
  VALIDATED_ROOT=$(deployed_repo) || die "installed deployment is not coherent"
  validate_installed_dashboard || die "dashboard launcher/runtime ownership, mode, or ancestry is untrusted"
  "$DASHBOARD_LAUNCHER" --provenance-validate 9>&- \
    || die "dashboard artifact closure validation failed"
  VALIDATED_MANIFEST_SHA=$(stable_sha256_file "$INSTALL_HOME/bin/kist-current.manifest") \
    || die "cannot bind the validated installed manifest identity"
  require_deployment_lease
  printf 'validated deployment: %s\n' "$VALIDATED_ROOT"
  printf 'manifest-sha256: %s\n' "$VALIDATED_MANIFEST_SHA"
  exit 0
fi

if [ "${1-}" = "--validate-enterprise" ]; then
  [ "$#" -eq 1 ] || die "--validate-enterprise takes no values"
  acquire_deployment_lease shared
  VALIDATED_ROOT=$(deployed_repo) || die "installed deployment is not coherent"
  validate_installed_dashboard || die "dashboard launcher/runtime ownership, mode, or ancestry is untrusted"
  "$DASHBOARD_LAUNCHER" --provenance-validate --require-enterprise 9>&- \
    || die "installed deployment does not have valid enterprise evidence, Developer ID signing, and notarization"
  require_deployment_lease
  printf 'validated enterprise local-candidate deployment: %s\n' "$VALIDATED_ROOT"
  exit 0
fi

if [ "${1-}" = "--finalize-enterprise-evidence" ]; then
  [ "$#" -eq 2 ] || die "--finalize-enterprise-evidence requires one absolute bundle path"
  case "$2" in /*) ;; *) die "enterprise evidence path must be absolute" ;; esac
  EVIDENCE_INPUT=$2
  acquire_deployment_lease exclusive
  transaction_control recover || die "cannot recover the previous deployment transaction"
  VALIDATED_ROOT=$(deployed_repo) || die "installed deployment is not a coherent schema-4 pilot"
  validate_installed_provenance_exclusive || die "pilot provenance validation failed"
  MANIFEST="$INSTALL_HOME/bin/kist-current.manifest"
  INSTALLED_BINARY="$INSTALL_HOME/bin/kist-current"
  CURRENT_ASSURANCE=$(/usr/bin/awk -F': ' '$1=="deployment-assurance" { if (seen++) exit 2; value=$2 } END { if (seen!=1) exit 3; print value }' "$MANIFEST") \
    || die "pilot manifest omitted deployment assurance"
  [ "$CURRENT_ASSURANCE" = pilot ] || die "only a schema-4 pilot may be finalized"
  MANIFEST_SOURCE=$(/usr/bin/awk -F': ' '$1=="source-state-sha256" { if (seen++) exit 2; value=$2 } END { if (seen!=1) exit 3; print value }' "$MANIFEST") \
    || die "pilot manifest omitted source state"
  CURRENT_SOURCE=$(source_state "$VALIDATED_ROOT") || die "cannot re-inventory the installed source"
  [ "$CURRENT_SOURCE" = "$MANIFEST_SOURCE" ] || die "source changed after installation; rebuild and rerun evidence"
  MANIFEST_UNSIGNED=$(/usr/bin/awk -F': ' '$1=="unsigned-release-sha256" { if (seen++) exit 2; value=$2 } END { if (seen!=1) exit 3; print value }' "$MANIFEST") \
    || die "pilot manifest omitted unsigned release hash"
  CURRENT_UNSIGNED=$(retained_unsigned_artifact_sha256 "$VALIDATED_ROOT" "$MANIFEST_UNSIGNED") \
    || die "the exact unsigned release artifact is unavailable; rebuild and rerun evidence"
  [ "$CURRENT_UNSIGNED" = "$MANIFEST_UNSIGNED" ] || die "unsigned release artifact changed after installation"

  TMP_FINAL_MANIFEST=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-current.manifest.final.XXXXXX")
  TMP_FINAL_EVIDENCE=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-current.provenance.final.XXXXXX")
  TMP_FINAL_PROJECTION=$(/usr/bin/mktemp "$INSTALL_HOME/bin/.kist-current.projection.final.XXXXXX")
  /bin/chmod -N "$TMP_FINAL_MANIFEST" "$TMP_FINAL_EVIDENCE" "$TMP_FINAL_PROJECTION" 2>/dev/null || true
  /bin/cp "$EVIDENCE_INPUT" "$TMP_FINAL_EVIDENCE" || die "cannot stage enterprise evidence"
  /bin/chmod 600 "$TMP_FINAL_MANIFEST" "$TMP_FINAL_EVIDENCE" "$TMP_FINAL_PROJECTION"
  FINALIZE_TRANSACTION_ACTIVE=0
  # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
  finalize_cleanup() {
    finalize_status=$?
    trap - 0 1 2 15
    if [ "$FINALIZE_TRANSACTION_ACTIVE" -eq 1 ]; then
      if ensure_exclusive_recovery_lease; then
        transaction_control rollback || finalize_status=1
      else
        finalize_status=1
      fi
      FINALIZE_TRANSACTION_ACTIVE=0
    fi
    /bin/rm -f "$TMP_FINAL_MANIFEST" "$TMP_FINAL_EVIDENCE" "$TMP_FINAL_PROJECTION"
    release_deployment_lease || finalize_status=1
    exit "$finalize_status"
  }
  trap finalize_cleanup 0
  trap 'exit 130' 2
  trap 'exit 143' 15
  enterprise_evidence_evaluate "$TMP_FINAL_EVIDENCE" "$MANIFEST" "$INSTALLED_BINARY" > "$TMP_FINAL_PROJECTION" \
    || die "enterprise evidence is missing, stale, malformed, or inconsistent"
  SIGNING_OUTPUT=$(signing_state "$INSTALLED_BINARY") || die "cannot inspect installed signing state"
  SIGNING_TYPE=$(printf '%s\n' "$SIGNING_OUTPUT" | /usr/bin/awk -F= '$1=="signing-type" {if(seen++)exit 2;v=substr($0,14)} END{if(seen!=1)exit 3;print v}') || die "signing inspection omitted type"
  SIGNING_IDENTITY=$(printf '%s\n' "$SIGNING_OUTPUT" | /usr/bin/awk -F= '$1=="signing-identity" {if(seen++)exit 2;v=substr($0,18)} END{if(seen!=1)exit 3;print v}') || die "signing inspection omitted identity"
  NOTARIZATION=$(printf '%s\n' "$SIGNING_OUTPUT" | /usr/bin/awk -F= '$1=="notarization-status" {if(seen++)exit 2;v=substr($0,21)} END{if(seen!=1)exit 3;print v}') || die "signing inspection omitted notarization"
  [ "$SIGNING_TYPE" = developer-id ] && [ "$NOTARIZATION" = accepted ] \
    || die "enterprise finalization requires a notarized Developer ID payload"
  MANIFEST_SIGNING_TYPE=$(/usr/bin/awk -F': ' '$1=="signing-type"{print $2}' "$MANIFEST")
  MANIFEST_SIGNING_IDENTITY=$(/usr/bin/awk -F': ' '$1=="signing-identity"{print $2}' "$MANIFEST")
  MANIFEST_NOTARIZATION=$(/usr/bin/awk -F': ' '$1=="notarization-status"{print $2}' "$MANIFEST")
  [ "$SIGNING_TYPE" = "$MANIFEST_SIGNING_TYPE" ] && [ "$SIGNING_IDENTITY" = "$MANIFEST_SIGNING_IDENTITY" ] \
    && [ "$NOTARIZATION" = "$MANIFEST_NOTARIZATION" ] || die "manifest signing state does not match the installed payload"

  python_clean - "$MANIFEST" "$TMP_FINAL_PROJECTION" "$TMP_FINAL_MANIFEST" <<'PY'
import os,sys
manifest,projection_path,target=sys.argv[1:]
projection={}
for line in open(projection_path,encoding="utf-8"):
    key,sep,value=line.rstrip("\n").partition("=")
    if not sep or not key or not value or key in projection: raise SystemExit(1)
    projection[key]=value
extras=["candidate-manifest-sha256","full-suite-evidence-sha256","full-suite-test-count","full-suite-failures","full-suite-errors","five-canary-evidence-sha256","five-canary-count","five-canary-failures","sbom-sha256","sbom-format","enterprise-evidence-sha256"]
if set(projection)!=set(extras)|{"deployment-evidence-sha256"}: raise SystemExit(1)
lines=[]; seen=set()
for raw in open(manifest,encoding="utf-8"):
    if not raw.endswith("\n") or ":" not in raw: raise SystemExit(1)
    key=raw.split(":",1)[0].strip().lower()
    if key in seen: raise SystemExit(1)
    seen.add(key)
    if key=="deployment-assurance": raw="deployment-assurance: enterprise\n"
    elif key=="test-evidence": raw="test-evidence: full-suite+installed-five-canaries\n"
    elif key=="deployment-evidence-sha256": raw=f"deployment-evidence-sha256: {projection[key]}\n"
    lines.append(raw)
for key in extras: lines.append(f"{key}: {projection[key]}\n")
payload="".join(lines).encode("utf-8")
fd=os.open(target,os.O_WRONLY|os.O_TRUNC|os.O_NOFOLLOW)
try:
    offset=0
    while offset<len(payload): offset+=os.write(fd,payload[offset:])
    os.fsync(fd)
finally: os.close(fd)
PY
  enterprise_evidence_evaluate "$TMP_FINAL_EVIDENCE" "$TMP_FINAL_MANIFEST" "$INSTALLED_BINARY" >/dev/null \
    || die "final enterprise manifest did not validate before promotion"
  FINALIZE_TRANSACTION_ACTIVE=1
  FINALIZE_TOKEN=$(transaction_control begin-finalize "$TMP_FINAL_MANIFEST" "$TMP_FINAL_EVIDENCE") \
    || die "enterprise finalization transaction could not be started"
  [ -n "$FINALIZE_TOKEN" ] || die "enterprise finalization transaction omitted its identity"
  require_deployment_lease exclusive
  deployed_repo >/dev/null || die "finalized deployment metadata is incoherent"
  validate_installed_provenance_exclusive \
    || die "finalized enterprise deployment failed semantic validation"
  require_deployment_lease exclusive
  transaction_control commit || die "enterprise finalization transaction could not be committed"
  FINALIZE_TRANSACTION_ACTIVE=0
  trap - 0 1 2 15
  /bin/rm -f "$TMP_FINAL_PROJECTION"
  release_deployment_lease
  printf 'enterprise local-candidate evidence finalized -> %s\n' "$INSTALL_HOME/bin/kist-current.provenance.json"
  exit 0
fi

FORCE=0
SIGN_IDENTITY=-
NOTARY_PROFILE=
FORCE_SEEN=0
SIGNING_SEEN=0
NOTARY_SEEN=0
SKIP_SUITE=0
SKIP_SUITE_SEEN=0
EXPECTED_INSTALLED_MANIFEST=
EXPECTED_INSTALLED_MANIFEST_SEEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      [ "$FORCE_SEEN" -eq 0 ] || die "--force may be supplied only once"
      FORCE=1; FORCE_SEEN=1; shift ;;
    --signing-identity)
      [ "$SIGNING_SEEN" -eq 0 ] && [ "$#" -ge 2 ] && [ -n "$2" ] || die "--signing-identity requires one value and may be supplied only once"
      SIGN_IDENTITY=$2; SIGNING_SEEN=1; shift 2 ;;
    --notary-keychain-profile)
      [ "$NOTARY_SEEN" -eq 0 ] && [ "$#" -ge 2 ] && [ -n "$2" ] || die "--notary-keychain-profile requires one value and may be supplied only once"
      NOTARY_PROFILE=$2; NOTARY_SEEN=1; shift 2 ;;
    --skip-suite)
      [ "$SKIP_SUITE_SEEN" -eq 0 ] || die "--skip-suite may be supplied only once"
      SKIP_SUITE=1; SKIP_SUITE_SEEN=1; shift ;;
    --expect-installed-manifest-sha256)
      [ "$EXPECTED_INSTALLED_MANIFEST_SEEN" -eq 0 ] && [ "$#" -ge 2 ] \
        || die "--expect-installed-manifest-sha256 requires one digest and may be supplied only once"
      EXPECTED_INSTALLED_MANIFEST=$2; EXPECTED_INSTALLED_MANIFEST_SEEN=1; shift 2 ;;
    *) die "usage: kist-rebuild [--force] [--skip-suite] [--signing-identity IDENTITY] [--notary-keychain-profile NAME] [--expect-installed-manifest-sha256 SHA256]" ;;
  esac
done
if [ -n "$EXPECTED_INSTALLED_MANIFEST" ]; then
  [ "${#EXPECTED_INSTALLED_MANIFEST}" -eq 64 ] \
    || die "expected installed manifest identity must be one lowercase SHA-256 digest"
  case "$EXPECTED_INSTALLED_MANIFEST" in
    *[!0-9a-f]*) die "expected installed manifest identity must be one lowercase SHA-256 digest" ;;
  esac
fi
if [ "$SIGN_IDENTITY" != - ]; then
  python_clean - "$SIGN_IDENTITY" <<'PY' || die "signing identity must be a printable single-line value of at most 512 characters"
import sys
value=sys.argv[1]
if not value or len(value)>512 or any(ord(c)<32 or ord(c)==127 for c in value): raise SystemExit(1)
PY
fi
if [ -n "$NOTARY_PROFILE" ]; then
  [ "$SIGN_IDENTITY" != - ] || die "notarization requires an explicit Developer ID signing identity"
  [ "${#NOTARY_PROFILE}" -le 128 ] || die "notary keychain profile name is too long"
  case "$NOTARY_PROFILE" in *[!A-Za-z0-9._-]*) die "notary keychain profile name contains unsafe characters" ;; esac
fi
acquire_deployment_lease exclusive
transaction_control recover || die "cannot recover the previous deployment transaction"
require_deployment_lease exclusive
if [ -n "$EXPECTED_INSTALLED_MANIFEST" ]; then
  ACTUAL_INSTALLED_MANIFEST=$(stable_sha256_file "$INSTALL_HOME/bin/kist-current.manifest") \
    || die "cannot read the expected installed manifest under the deployment lease"
  [ "$ACTUAL_INSTALLED_MANIFEST" = "$EXPECTED_INSTALLED_MANIFEST" ] \
    || die "installed deployment changed after selection; rerun the safe rebuild"
fi

if [ -n "${MYTHOS_REPO-}" ]; then
  REPO=$(validated_repo "$MYTHOS_REPO") \
    || die "MYTHOS_REPO=$MYTHOS_REPO is not one canonical Kist repo"
elif REPO=$(deployed_repo); then
  :
else
  die "no canonical Kist repo selected; set MYTHOS_REPO or repair the validated deployed provenance"
fi

