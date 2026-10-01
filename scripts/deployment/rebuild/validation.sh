# Validate one retained enterprise evidence bundle. The bundle contains the evidence bytes, not
# merely caller-supplied digests, and is deliberately described as local-candidate provenance: it
# is not a SLSA attestation. Output is a small canonical key=value projection for manifest creation.
enterprise_evidence_evaluate() {
  resource_python "$1" "$2" "$3" <<'PY'
import base64,binascii,hashlib,json,os,stat,sys,xml.etree.ElementTree as ET
bundle_path,manifest_path,binary_path=sys.argv[1:]
HEX=set("0123456789abcdef")
BASE_REQUIRED_LEGACY={
 "schema","stamp","deployed","worktree","branch","commit","remote-origin-sha256","repository-id",
 "source-dirty","source-state-sha256","binary-sha256","wrapper-sha256","dashboard-launcher-sha256",
 "rebuild-sha256","safe-rebuild-sha256","artifact-closure-sha256","artifact-closure-count","test-evidence",
 "deployment-assurance","provenance-kind","unsigned-release-sha256","signed-installed-sha256","signing-type",
 "signing-identity","notarization-status","notarization-submission-id","notarization-package-sha256",
 "deployment-evidence-sha256","product-version",
}
OPERATIONAL_REQUIRED={"dashboard-runtime-sha256","dashboard-cortex-sha256","dashboard-cortex-count"}
ENTERPRISE_REQUIRED={
 "candidate-manifest-sha256","full-suite-evidence-sha256","full-suite-test-count","full-suite-failures",
 "full-suite-errors","five-canary-evidence-sha256","five-canary-count","five-canary-failures","sbom-sha256",
 "sbom-format","enterprise-evidence-sha256",
}
def valid_hash(value): return type(value) is str and len(value)==64 and all(c in HEX for c in value)
def stable_read(path,limit,executable=False):
    if not os.path.isabs(path) or os.path.realpath(path)!=path: raise SystemExit(1)
    before=os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid!=os.geteuid() or before.st_nlink!=1
            or before.st_mode&0o022 or before.st_size>limit or (executable and not before.st_mode&stat.S_IXUSR)):
        raise SystemExit(1)
    identity=(before.st_dev,before.st_ino,before.st_mode,before.st_uid,before.st_size,before.st_nlink,before.st_mtime_ns,before.st_ctime_ns)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        current=os.fstat(fd)
        if (current.st_dev,current.st_ino,current.st_mode,current.st_uid,current.st_size,current.st_nlink,current.st_mtime_ns,current.st_ctime_ns)!=identity: raise SystemExit(1)
        chunks=[]; remaining=before.st_size
        while remaining:
            block=os.read(fd,min(1024*1024,remaining))
            if not block: raise SystemExit(1)
            chunks.append(block); remaining-=len(block)
        if os.read(fd,1): raise SystemExit(1)
        current=os.fstat(fd); named=os.lstat(path)
        for value in (current,named):
            if (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)!=identity: raise SystemExit(1)
        return b"".join(chunks)
    finally: os.close(fd)
def fields(raw):
    try: text=raw.decode("utf-8")
    except UnicodeDecodeError: raise SystemExit(1)
    if not text.endswith("\n") or "\r" in text: raise SystemExit(1)
    result={}
    for line in text.splitlines():
        if not line or ":" not in line: raise SystemExit(1)
        key,value=line.split(":",1); key=key.strip().lower(); value=value.strip()
        if not key or not value or key in result: raise SystemExit(1)
        result[key]=value
    return result
def decode(value,limit):
    if type(value) is not str or len(value)>((limit+2)//3)*4+4: raise SystemExit(1)
    try: raw=base64.b64decode(value.encode("ascii"),validate=True)
    except (UnicodeEncodeError,binascii.Error): raise SystemExit(1)
    if len(raw)>limit or base64.b64encode(raw).decode("ascii")!=value: raise SystemExit(1)
    return raw
def natural(value,positive=False):
    if type(value) is not int or isinstance(value,bool) or value<0 or (positive and value==0): raise SystemExit(1)
    return value
def digest(raw,claimed):
    if not valid_hash(claimed) or hashlib.sha256(raw).hexdigest()!=claimed: raise SystemExit(1)

manifest_raw=stable_read(manifest_path,262144)
current=fields(manifest_raw)
if current.get("schema")!="4" or current.get("deployment-assurance") not in {"pilot","enterprise"}: raise SystemExit(1)
operational_bound=bool(OPERATIONAL_REQUIRED&set(current))
base_required=BASE_REQUIRED_LEGACY|(OPERATIONAL_REQUIRED if operational_bound else set())
resource_fields=set(RESOURCE_KEYS.values())
if resource_fields&set(current):
    base_required|=resource_fields|OPERATIONAL_REQUIRED
    if any(not valid_hash(current.get(key)) for key in resource_fields): raise SystemExit(1)
expected=base_required|(ENTERPRISE_REQUIRED if current["deployment-assurance"]=="enterprise" else set())
if set(current)!=expected or current.get("provenance-kind")!="local-candidate": raise SystemExit(1)
import re
semver=r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
if not re.fullmatch(semver,current.get("product-version","")): raise SystemExit(1)
for key in ["source-state-sha256","unsigned-release-sha256","signed-installed-sha256","binary-sha256","deployment-evidence-sha256"]:
    if not valid_hash(current.get(key)): raise SystemExit(1)
if operational_bound:
    if not valid_hash(current.get("dashboard-runtime-sha256")) or not valid_hash(current.get("dashboard-cortex-sha256")): raise SystemExit(1)
    cortex_count=current.get("dashboard-cortex-count","")
    if not cortex_count.isdigit() or str(int(cortex_count))!=cortex_count: raise SystemExit(1)
if current["signed-installed-sha256"]!=current["binary-sha256"]: raise SystemExit(1)
if current.get("notarization-status")=="accepted":
    if not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",current.get("notarization-submission-id","")) or not valid_hash(current.get("notarization-package-sha256")): raise SystemExit(1)
elif current.get("notarization-status")!="not-accepted" or current.get("notarization-submission-id")!="none" or current.get("notarization-package-sha256")!="none": raise SystemExit(1)
binary=stable_read(binary_path,512*1024*1024,True)
if hashlib.sha256(binary).hexdigest()!=current["signed-installed-sha256"]: raise SystemExit(1)

bundle_raw=stable_read(bundle_path,64*1024*1024)
try: bundle=json.loads(bundle_raw)
except (UnicodeDecodeError,json.JSONDecodeError): raise SystemExit(1)
if type(bundle) is not dict or set(bundle)!={"schema","assurance","provenance_kind","source_state_sha256","unsigned_release_sha256","signed_installed_sha256","candidate_manifest_sha256","candidate_manifest_base64","full_suite","five_canaries","sbom"}: raise SystemExit(1)
if bundle.get("schema")!=1 or bundle.get("assurance")!="enterprise" or bundle.get("provenance_kind")!="local-candidate": raise SystemExit(1)
canonical=(json.dumps(bundle,sort_keys=True,separators=(",",":"),ensure_ascii=True)+"\n").encode()
if canonical!=bundle_raw: raise SystemExit(1)
for key in ["source_state_sha256","unsigned_release_sha256","signed_installed_sha256","candidate_manifest_sha256"]:
    if not valid_hash(bundle.get(key)): raise SystemExit(1)
if bundle["source_state_sha256"]!=current["source-state-sha256"] or bundle["unsigned_release_sha256"]!=current["unsigned-release-sha256"] or bundle["signed_installed_sha256"]!=current["signed-installed-sha256"]: raise SystemExit(1)

candidate_raw=decode(bundle["candidate_manifest_base64"],262144); digest(candidate_raw,bundle["candidate_manifest_sha256"])
candidate=fields(candidate_raw)
if set(candidate)!=base_required or candidate.get("schema")!="4" or candidate.get("deployment-assurance")!="pilot" or candidate.get("provenance-kind")!="local-candidate": raise SystemExit(1)
for key in base_required-{"deployment-assurance","test-evidence","deployment-evidence-sha256"}:
    if current.get(key)!=candidate.get(key): raise SystemExit(1)
if current["deployment-assurance"]=="pilot" and candidate_raw!=manifest_raw: raise SystemExit(1)
if current["deployment-assurance"]=="enterprise" and current.get("candidate-manifest-sha256")!=bundle["candidate_manifest_sha256"]: raise SystemExit(1)

suite=bundle["full_suite"]
if type(suite) is not dict or set(suite)!={"content_base64","sha256","tests","failures","errors"}: raise SystemExit(1)
suite_raw=decode(suite["content_base64"],32*1024*1024); digest(suite_raw,suite["sha256"])
if b"<!DOCTYPE" in suite_raw.upper() or b"<!ENTITY" in suite_raw.upper(): raise SystemExit(1)
try: xml=ET.fromstring(suite_raw)
except ET.ParseError: raise SystemExit(1)
nodes=[xml] if xml.tag.rsplit("}",1)[-1]=="testsuite" else [node for node in list(xml) if node.tag.rsplit("}",1)[-1]=="testsuite"]
if not nodes: raise SystemExit(1)
def xml_count(node,name):
    value=node.attrib.get(name,"0")
    if not value.isdigit() or str(int(value))!=value: raise SystemExit(1)
    return int(value)
xml_tests=sum(xml_count(node,"tests") for node in nodes); xml_failures=sum(xml_count(node,"failures") for node in nodes); xml_errors=sum(xml_count(node,"errors") for node in nodes)
if natural(suite["tests"],True)!=xml_tests or natural(suite["failures"])!=xml_failures or natural(suite["errors"])!=xml_errors or xml_failures or xml_errors: raise SystemExit(1)

canary=bundle["five_canaries"]
if type(canary) is not dict or set(canary)!={"content_base64","sha256","count","failures"}: raise SystemExit(1)
canary_raw=decode(canary["content_base64"],1024*1024); digest(canary_raw,canary["sha256"])
try: canary_doc=json.loads(canary_raw)
except (UnicodeDecodeError,json.JSONDecodeError): raise SystemExit(1)
if type(canary_doc) is not dict or set(canary_doc)!={"schema","binary_sha256","source_state_sha256","canaries"} or canary_doc.get("schema")!=1: raise SystemExit(1)
if (json.dumps(canary_doc,sort_keys=True,separators=(",",":"),ensure_ascii=True)+"\n").encode()!=canary_raw: raise SystemExit(1)
if canary_doc.get("binary_sha256")!=current["signed-installed-sha256"] or canary_doc.get("source_state_sha256")!=current["source-state-sha256"]: raise SystemExit(1)
expected_names={"observe","whole-computer","local-research","fetch-only","live-tavily"}; records=canary_doc.get("canaries")
if type(records) is not list or len(records)!=5: raise SystemExit(1)
names=set()
for record in records:
    if type(record) is not dict or set(record)!={"name","status"} or record.get("name") not in expected_names or record.get("status")!="pass" or record["name"] in names: raise SystemExit(1)
    names.add(record["name"])
if names!=expected_names or natural(canary["count"])!=5 or natural(canary["failures"])!=0: raise SystemExit(1)

sbom=bundle["sbom"]
if type(sbom) is not dict or set(sbom)!={"content_base64","sha256","format"} or sbom.get("format")!="cyclonedx-1.7-json": raise SystemExit(1)
sbom_raw=decode(sbom["content_base64"],8*1024*1024); digest(sbom_raw,sbom["sha256"])
try: sbom_doc=json.loads(sbom_raw)
except (UnicodeDecodeError,json.JSONDecodeError): raise SystemExit(1)
if type(sbom_doc) is not dict or sbom_doc.get("bomFormat")!="CycloneDX" or sbom_doc.get("specVersion")!="1.7": raise SystemExit(1)
metadata=sbom_doc.get("metadata"); properties=metadata.get("properties") if type(metadata) is dict else None
if type(properties) is not list: raise SystemExit(1)
bound={}
trusted={"kist:source-state-sha256","kist:unsigned-release-sha256","kist:product-version"}
for item in properties:
    if type(item) is dict and item.get("name") in trusted:
        if set(item)!={"name","value"} or item["name"] in bound or type(item.get("value")) is not str: raise SystemExit(1)
        bound[item["name"]]=item["value"]
if bound!={"kist:source-state-sha256":current["source-state-sha256"],"kist:unsigned-release-sha256":current["unsigned-release-sha256"],"kist:product-version":current["product-version"]}: raise SystemExit(1)

bundle_hash=hashlib.sha256(bundle_raw).hexdigest()
projection={
 "candidate-manifest-sha256":bundle["candidate_manifest_sha256"],
 "full-suite-evidence-sha256":suite["sha256"],"full-suite-test-count":str(suite["tests"]),
 "full-suite-failures":str(suite["failures"]),"full-suite-errors":str(suite["errors"]),
 "five-canary-evidence-sha256":canary["sha256"],"five-canary-count":"5","five-canary-failures":"0",
 "sbom-sha256":sbom["sha256"],"sbom-format":"cyclonedx-1.7-json",
 "enterprise-evidence-sha256":bundle_hash,"deployment-evidence-sha256":bundle_hash,
}
if current["deployment-assurance"]=="enterprise":
    for key,value in projection.items():
        if current.get(key)!=value: raise SystemExit(1)
for key in sorted(projection): print(f"{key}={projection[key]}")
PY
}

# Report the actual code-signing and Gatekeeper state. Identity values are public certificate
# metadata; keychain material and notarization credentials are never read or printed.
signing_state() {
  python_clean - "$1" <<'PY'
import os,subprocess,sys
path=sys.argv[1]
if not os.path.isabs(path) or os.path.realpath(path)!=path: raise SystemExit(1)
try:
    verification=subprocess.run(
        ["/usr/bin/codesign","--verify","--strict","--all-architectures",path],
        stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
except (OSError,subprocess.TimeoutExpired):
    raise SystemExit(1)
if verification.returncode: raise SystemExit(1)
codesign=subprocess.run(["/usr/bin/codesign","-d","--verbose=4",path],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=15)
if codesign.returncode: raise SystemExit(1)
try: lines=codesign.stderr.decode("utf-8").splitlines()
except UnicodeDecodeError: raise SystemExit(1)
signature=next((line.split("=",1)[1] for line in lines if line.startswith("Signature=")),"")
authorities=[line.split("=",1)[1] for line in lines if line.startswith("Authority=")]
if signature=="adhoc": kind,identity="ad-hoc","adhoc"
elif authorities and authorities[0].startswith("Developer ID Application:"): kind,identity="developer-id",authorities[0]
else: kind,identity="other",(authorities[0] if authorities else "unknown")
if not identity or len(identity)>512 or any(ord(c)<32 or ord(c)==127 for c in identity): raise SystemExit(1)
notarization="not-accepted"
try:
    gate=subprocess.run(["/usr/sbin/spctl","--assess","--type","execute","--verbose=4",path],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
    report=(gate.stdout+gate.stderr).decode("utf-8","replace")
    if gate.returncode==0 and "source=Notarized Developer ID" in report: notarization="accepted"
except (OSError,subprocess.TimeoutExpired): pass
print("signing-type="+kind); print("signing-identity="+identity); print("notarization-status="+notarization)
PY
}

# Read-only evidence plumbing is available before any deployment lease, network access, build, or
# mutation. CI uses the exact production source-state implementation to bind its test invocation.
if [ "${1-}" = "--print-source-state" ]; then
  [ "$#" -le 2 ] || die "usage: kist-rebuild --print-source-state [ABSOLUTE_REPO]"
  PRINT_ROOT=${2:-$PWD}
  PRINT_ROOT=$(validated_repo "$PRINT_ROOT") || die "source-state root is not one canonical Kist repo"
  source_state "$PRINT_ROOT" || die "cannot compute source state"
  exit 0
fi
if [ "${1-}" = "--test-snapshot-source" ]; then
  [ "${KIST_REBUILD_TESTING-}" = 1 ] && [ "$INSTALL_HOME" != /Users/lukekist ] \
    || die "source snapshot test seam is unavailable in production"
  [ "$#" -eq 3 ] || die "--test-snapshot-source requires ABSOLUTE_REPO ABSOLUTE_EMPTY_DESTINATION"
  SNAPSHOT_TEST_ROOT=$(validated_repo "$2") || die "snapshot test root is not one canonical Kist repo"
  case "$3" in /*) ;; *) die "snapshot test destination must be absolute" ;; esac
  snapshot_source "$SNAPSHOT_TEST_ROOT" "$3" || die "source snapshot test failed"
  exit 0
fi
if [ "${1-}" = "--test-publish-unsigned-artifact" ]; then
  [ "${KIST_REBUILD_TESTING-}" = 1 ] && [ "$INSTALL_HOME" != /Users/lukekist ] \
    || die "unsigned artifact test seam is unavailable in production"
  [ "$#" -eq 3 ] || die "--test-publish-unsigned-artifact requires ABSOLUTE_REPO ABSOLUTE_SOURCE"
  UNSIGNED_TEST_ROOT=$(validated_repo "$2") \
    || die "unsigned artifact test root is not one canonical Kist repo"
  case "$3" in /*) ;; *) die "unsigned artifact test source must be absolute" ;; esac
  publish_unsigned_artifact "$UNSIGNED_TEST_ROOT" "$3" \
    || die "unsigned artifact publication test failed"
  exit 0
fi
if [ "${1-}" = "--test-hash-retained-unsigned-artifact" ]; then
  [ "${KIST_REBUILD_TESTING-}" = 1 ] && [ "$INSTALL_HOME" != /Users/lukekist ] \
    || die "unsigned artifact test seam is unavailable in production"
  [ "$#" -eq 3 ] \
    || die "--test-hash-retained-unsigned-artifact requires ABSOLUTE_REPO SHA256"
  UNSIGNED_TEST_ROOT=$(validated_repo "$2") \
    || die "unsigned artifact test root is not one canonical Kist repo"
  retained_unsigned_artifact_sha256 "$UNSIGNED_TEST_ROOT" "$3" \
    || die "retained unsigned artifact test failed"
  exit 0
fi
if [ "${1-}" = "--evidence-evaluate" ]; then
  [ "$#" -eq 4 ] || die "--evidence-evaluate requires BUNDLE MANIFEST BINARY"
  enterprise_evidence_evaluate "$2" "$3" "$4" || die "enterprise evidence is missing, stale, malformed, or inconsistent"
  exit 0
fi
if [ "${1-}" = "--signing-evaluate" ]; then
  [ "$#" -eq 2 ] || die "--signing-evaluate requires BINARY"
  signing_state "$2" || die "cannot inspect code-signing state"
  exit 0
fi

# Validate schema-3 compatibility deployments and every schema-4 field against canonical repository
# identity and installed artifacts. The only output on success is the canonical worktree.
deployed_repo() {
  resource_python "$INSTALL_HOME" <<'PY'
import hashlib
import ctypes,errno,os
import stat
import selectors,signal,subprocess,time
import sys

home = os.path.realpath(sys.argv[1])
stamp_path = os.path.join(home, "bin", ".kist-build")
manifest_path = os.path.join(home, "bin", "kist-current.manifest")
binary_path = os.path.join(home, "bin", "kist-current")
wrapper_path = os.path.join(home, "bin", "kist")
launcher_path = os.path.join(home, "bin", "kist-dashboard")
rebuild_path = os.path.join(home, "bin", "kist-rebuild")
safe_rebuild_path = os.path.join(home, "bin", "kist-safe-rebuild.sh")
runtime_path = os.path.join(home, ".kist", "scripts", "kist_runtime.py")
evidence_path = os.path.join(home, "bin", "kist-current.provenance.json")
artifacts = [stamp_path, manifest_path, binary_path, wrapper_path, launcher_path, rebuild_path, runtime_path]
if any(not stat.S_ISREG(os.lstat(path).st_mode) for path in artifacts):
    raise SystemExit(1)

def fp(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_size,
            value.st_nlink, value.st_mtime_ns, value.st_ctime_ns)
libc=ctypes.CDLL(None,use_errno=True)
libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]
libc.acl_get_fd_np.restype=ctypes.c_void_p
libc.acl_free.argtypes=[ctypes.c_void_p]
def acl(fd):
    ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
    if value:
        libc.acl_free(value); return True
    if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}:
        return False
    raise SystemExit(1)

def stable_read_bin(name: str, limit: int) -> str:
    parent=os.path.dirname(home); home_name=os.path.basename(home)
    pfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW); pid=fp(os.fstat(pfd))
    try:
        hst=os.stat(home_name,dir_fd=pfd,follow_symlinks=False); hid=fp(hst)
        if not stat.S_ISDIR(hst.st_mode) or hst.st_uid!=os.geteuid() or hst.st_mode&0o022: raise SystemExit(1)
        hfd=os.open(home_name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=pfd)
        try:
            if fp(os.fstat(hfd))!=hid: raise SystemExit(1)
            bst=os.stat("bin",dir_fd=hfd,follow_symlinks=False); bid=fp(bst)
            if not stat.S_ISDIR(bst.st_mode) or bst.st_uid!=os.geteuid() or bst.st_mode&0o022: raise SystemExit(1)
            bfd=os.open("bin",os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=hfd)
            try:
                if fp(os.fstat(bfd))!=bid or acl(bfd): raise SystemExit(1)
                st=os.stat(name,dir_fd=bfd,follow_symlinks=False); before=fp(st)
                if (not stat.S_ISREG(st.st_mode) or st.st_uid!=os.geteuid() or st.st_nlink!=1
                        or st.st_mode&0o022 or st.st_size>limit): raise SystemExit(1)
                fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=bfd)
                try:
                    if fp(os.fstat(fd))!=before or acl(fd): raise SystemExit(1)
                    chunks=[]; total=0
                    while True:
                        block=os.read(fd,min(65536,limit-total+1))
                        if not block: break
                        total+=len(block)
                        if total>limit: raise SystemExit(1)
                        chunks.append(block)
                    if fp(os.fstat(fd))!=before or fp(os.stat(name,dir_fd=bfd,follow_symlinks=False))!=before: raise SystemExit(1)
                finally: os.close(fd)
                if fp(os.fstat(bfd))!=bid or fp(os.stat("bin",dir_fd=hfd,follow_symlinks=False))!=bid: raise SystemExit(1)
                if fp(os.fstat(hfd))!=hid or fp(os.stat(home_name,dir_fd=pfd,follow_symlinks=False))!=hid or fp(os.fstat(pfd))!=pid: raise SystemExit(1)
                return b"".join(chunks).decode("utf-8")
            finally: os.close(bfd)
        finally: os.close(hfd)
    finally: os.close(pfd)
raw_stamp=stable_read_bin(".kist-build",16384)
if not raw_stamp.endswith("\n") or "\r" in raw_stamp or "\n" in raw_stamp[:-1]:
    raise SystemExit(1)
stamp_line = raw_stamp[:-1]
stamp = stamp_line.split(" · ", 3)
if len(stamp) != 4 or not all(stamp) or not (7 <= len(stamp[0]) <= 64):
    raise SystemExit(1)

fields = {}
for raw in stable_read_bin("kist-current.manifest",262144).splitlines(keepends=True):
        line = raw.rstrip("\r\n")
        if not line:
            continue
        if ":" not in line:
            raise SystemExit(1)
        key, value = line.split(":", 1)
        key, value = key.strip().lower(), value.strip()
        if not key or not value or key in fields:
            raise SystemExit(1)
        fields[key] = value

schema3_required = {
    "schema", "stamp", "deployed", "worktree", "branch", "commit", "remote-origin-sha256",
    "repository-id", "source-dirty", "source-state-sha256", "binary-sha256", "wrapper-sha256",
    "dashboard-launcher-sha256", "rebuild-sha256", "dashboard-runtime-sha256", "artifact-closure-sha256",
    "artifact-closure-count", "test-evidence",
}
schema4_extras = {
    "deployment-assurance", "provenance-kind", "unsigned-release-sha256", "signed-installed-sha256",
    "signing-type", "signing-identity", "notarization-status", "notarization-submission-id",
    "notarization-package-sha256", "deployment-evidence-sha256", "product-version",
}
schema4_legacy_base = schema3_required | schema4_extras
schema4_v3_legacy_base = (schema3_required - {"dashboard-runtime-sha256"}) | schema4_extras | {
    "safe-rebuild-sha256",
}
schema4_v3_operational = {
    "dashboard-runtime-sha256", "dashboard-cortex-sha256", "dashboard-cortex-count",
}
schema4_v3_base = schema4_v3_legacy_base | schema4_v3_operational
resource_fields = set(RESOURCE_KEYS.values())
schema4_enterprise = {
    "candidate-manifest-sha256", "full-suite-evidence-sha256", "full-suite-test-count",
    "full-suite-failures", "full-suite-errors", "five-canary-evidence-sha256", "five-canary-count",
    "five-canary-failures", "sbom-sha256", "sbom-format", "enterprise-evidence-sha256",
}
schema=fields.get("schema"); operational_bound=False
if schema=="3":
    required=schema3_required; closure_version=2
elif schema=="4" and fields.get("deployment-assurance") in {"pilot","enterprise"}:
    if resource_fields&set(fields):
        required=schema4_v3_base|resource_fields
        closure_version=4; operational_bound=True
    elif "safe-rebuild-sha256" in fields:
        closure_version=3
        if schema4_v3_operational&set(fields):
            required=schema4_v3_base; operational_bound=True
        else:
            required=schema4_v3_legacy_base
    else:
        required=schema4_legacy_base; closure_version=2
    if fields["deployment-assurance"]=="enterprise": required=required|schema4_enterprise
else: raise SystemExit(1)
if set(fields) != required or fields["stamp"] != stamp_line:
    raise SystemExit(1)
launcher_raw=stable_read_bin("kist-dashboard",16*1024*1024).encode("utf-8")
if hashlib.sha256(launcher_raw).hexdigest()!=fields["dashboard-launcher-sha256"]:
    raise SystemExit(1)
if closure_version>=3:
    stable_read_bin("kist-safe-rebuild.sh",16*1024*1024)
if fields["deployed"] != stamp[2] or fields["worktree"] != stamp[3] or fields["branch"] != stamp[1]:
    raise SystemExit(1)
if fields["source-dirty"] not in {"yes", "no"} or fields["test-evidence"].lower() == "yes":
    raise SystemExit(1)
def valid_hex(value: str, minimum: int, maximum: int) -> bool:
    return minimum <= len(value) <= maximum and all(character in "0123456789abcdefABCDEF" for character in value)
if not valid_hex(stamp[0], 7, 64) or not valid_hex(fields["commit"], 40, 64):
    raise SystemExit(1)
if not fields["commit"].lower().startswith(stamp[0].lower()):
    raise SystemExit(1)
hash_fields=["remote-origin-sha256", "repository-id", "source-state-sha256", "binary-sha256",
             "wrapper-sha256", "dashboard-launcher-sha256", "rebuild-sha256",
             "artifact-closure-sha256"]
hash_fields.append("safe-rebuild-sha256" if closure_version>=3 else "dashboard-runtime-sha256")
if closure_version==4: hash_fields.extend(resource_fields)
if operational_bound:
    hash_fields.extend(["dashboard-runtime-sha256","dashboard-cortex-sha256"])
for key in hash_fields:
    if not valid_hex(fields[key], 64, 64):
        raise SystemExit(1)
if operational_bound:
    cortex_count=fields["dashboard-cortex-count"]
    if not cortex_count.isdigit() or str(int(cortex_count))!=cortex_count:
        raise SystemExit(1)
if schema=="4":
    import re
    semver=r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    if not re.fullmatch(semver,fields["product-version"]): raise SystemExit(1)
    for key in ["unsigned-release-sha256","signed-installed-sha256","deployment-evidence-sha256"]:
        if not valid_hex(fields[key],64,64): raise SystemExit(1)
    if fields["signed-installed-sha256"]!=fields["binary-sha256"] or fields["provenance-kind"]!="local-candidate": raise SystemExit(1)
    if fields["signing-type"] not in {"ad-hoc","developer-id","other"} or fields["notarization-status"] not in {"accepted","not-accepted"}: raise SystemExit(1)
    if not fields["signing-identity"] or len(fields["signing-identity"])>512 or any(ord(c)<32 or ord(c)==127 for c in fields["signing-identity"]): raise SystemExit(1)
    if fields["notarization-status"]=="accepted":
        import re
        if not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",fields["notarization-submission-id"]): raise SystemExit(1)
        if not valid_hex(fields["notarization-package-sha256"],64,64): raise SystemExit(1)
    elif fields["notarization-submission-id"]!="none" or fields["notarization-package-sha256"]!="none": raise SystemExit(1)
    evidence=stable_read_bin("kist-current.provenance.json",64*1024*1024).encode("utf-8")
    if hashlib.sha256(evidence).hexdigest()!=fields["deployment-evidence-sha256"]: raise SystemExit(1)
    if fields["deployment-assurance"]=="enterprise":
        for key in ["candidate-manifest-sha256","full-suite-evidence-sha256","five-canary-evidence-sha256","sbom-sha256","enterprise-evidence-sha256"]:
            if not valid_hex(fields[key],64,64): raise SystemExit(1)
        if fields["enterprise-evidence-sha256"]!=fields["deployment-evidence-sha256"] or fields["sbom-format"]!="cyclonedx-1.7-json": raise SystemExit(1)
        for key,positive in [("full-suite-test-count",True),("full-suite-failures",False),("full-suite-errors",False),("five-canary-count",True),("five-canary-failures",False)]:
            value=fields[key]
            if not value.isdigit() or str(int(value))!=value or (positive and int(value)<=0): raise SystemExit(1)
        if fields["full-suite-failures"]!="0" or fields["full-suite-errors"]!="0" or fields["five-canary-count"]!="5" or fields["five-canary-failures"]!="0": raise SystemExit(1)

root = os.path.realpath(fields["worktree"])
if root != fields["worktree"]:
    raise SystemExit(1)
git = "/usr/bin/git"
git_env = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/empty", "LANG": "C", "LC_ALL": "C",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0",
    "GIT_TERMINAL_PROMPT": "0",
}
def git_data(*args: str) -> bytes:
    process = subprocess.Popen(
        [git, "-C", root, "--no-pager", "-c", "core.hooksPath=/dev/null",
         "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
         "-c", "credential.helper=", "-c", "maintenance.auto=false", *args],
        env=git_env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True)
    selector=selectors.DefaultSelector(); selector.register(process.stdout,selectors.EVENT_READ,0); selector.register(process.stderr,selectors.EVENT_READ,1)
    buffers=[bytearray(),bytearray()]; deadline=time.monotonic()+10
    try:
        while selector.get_map():
            if time.monotonic()>deadline: raise TimeoutError()
            for key,_ in selector.select(.1):
                block=os.read(key.fileobj.fileno(),65536)
                if not block: selector.unregister(key.fileobj); continue
                buffers[key.data]+=block
                if len(buffers[key.data])>2*1024*1024: raise OverflowError()
        code=process.wait(timeout=max(.1,deadline-time.monotonic()))
        if code: raise subprocess.CalledProcessError(code,process.args)
        return bytes(buffers[0])
    except Exception:
        try: os.killpg(process.pid,signal.SIGTERM); process.wait(timeout=1)
        except Exception:
            try: os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError: pass
        raise
def git_text(*args: str) -> str:
    return git_data(*args).decode("utf-8").strip()

top = os.path.realpath(git_text("rev-parse", "--show-toplevel"))
common_raw = git_text("rev-parse", "--git-common-dir")
common = os.path.realpath(common_raw if os.path.isabs(common_raw) else os.path.join(root, common_raw))
try:
    remote = git_data("config", "--get", "remote.origin.url").decode("utf-8")
    if remote.endswith("\n"): remote=remote[:-1]
    if remote.endswith("\r"): remote=remote[:-1]
    if not remote or "\n" in remote or "\r" in remote: raise SystemExit(1)
except subprocess.CalledProcessError:
    remote = "(none)"
def normalize_remote(value: str) -> str:
    if not value or any(c.isspace() or c=="\0" for c in value): raise SystemExit(1)
    cuts=[i for i in (value.find("?"),value.find("#")) if i>=0]
    value=value[:min(cuts)] if cuts else value
    if "://" in value:
        scheme,rest=value.split("://",1); authority,sep,path=rest.partition("/")
        authority=authority.rsplit("@",1)[-1]
        if not scheme or not authority: raise SystemExit(1)
        return scheme.lower()+"://"+authority.lower()+(sep+path if sep else "")
    colon=value.find(":"); slash=value.find("/")
    if colon>=0 and (slash<0 or colon<slash):
        host=value[:colon].rsplit("@",1)[-1]
        if not host: raise SystemExit(1)
        return host.lower()+value[colon:]
    return value
remote_hash = hashlib.sha256(normalize_remote(remote).encode()).hexdigest()
repository_id = hashlib.sha256(f"{remote_hash}\n{common}\n".encode()).hexdigest()
if top != root or remote_hash != fields["remote-origin-sha256"] or repository_id != fields["repository-id"]:
    raise SystemExit(1)

evaluation_args=[launcher_path,"--provenance-evaluate",binary_path,wrapper_path]
if closure_version>=3:
    evaluation_args += [launcher_path,rebuild_path,safe_rebuild_path]
if closure_version==4:
    evaluation_args += [resource_destination(os.path.join(home,"bin"),alias)
                        for alias in RESOURCE_FILES]
evaluation = subprocess.run(evaluation_args,
                            stdout=subprocess.PIPE,timeout=30,check=True)
if len(evaluation.stdout)>65536: raise SystemExit(1)
computed={}
for line in evaluation.stdout.decode().splitlines():
    key,sep,value=line.partition("=")
    if not sep or key in computed: raise SystemExit(1)
    computed[key]=value
closure_keys=["binary-sha256","wrapper-sha256","dashboard-launcher-sha256","rebuild-sha256",
              "artifact-closure-sha256","artifact-closure-count"]
closure_keys.append("safe-rebuild-sha256" if closure_version>=3 else "dashboard-runtime-sha256")
if closure_version==4: closure_keys.extend(resource_fields)
if operational_bound:
    closure_keys.extend(["dashboard-runtime-sha256","dashboard-cortex-sha256","dashboard-cortex-count"])
for key in closure_keys:
    if computed.get(key)!=fields[key]: raise SystemExit(1)
print(root)
PY
}

validate_installed_dashboard() {
  python_clean - "$DASHBOARD_LAUNCHER" "$DASHBOARD_REBUILD" "$DASHBOARD_RUNTIME" <<'PY'
import ctypes,errno,os,pwd
import stat
import sys

uid = os.geteuid()
account_home=os.path.realpath(pwd.getpwuid(uid).pw_dir)
libc=ctypes.CDLL(None,use_errno=True);libc.acl_get_fd_np.restype=ctypes.c_void_p;libc.acl_free.argtypes=[ctypes.c_void_p]
def has_acl(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
        if value: libc.acl_free(value); return True
        if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
        raise SystemExit(1)
    finally: os.close(fd)
for index, path in enumerate(sys.argv[1:]):
    if not os.path.isabs(path):
        raise SystemExit(1)
    current = "/"
    parts = [part for part in path.split("/") if part]
    paths = [current]
    for part in parts:
        current = os.path.join(current, part)
        paths.append(current)
    for offset, item in enumerate(paths):
        info = os.lstat(item)
        leaf = offset == len(paths) - 1
        if (leaf and (not stat.S_ISREG(info.st_mode) or info.st_nlink!=1)) or (not leaf and not stat.S_ISDIR(info.st_mode)):
            raise SystemExit(1)
        if info.st_uid not in {0, uid} or info.st_mode & 0o022:
            raise SystemExit(1)
        if item != account_home:
            if has_acl(item): raise SystemExit(1)
        if leaf and info.st_uid != uid:
            raise SystemExit(1)
        if leaf and not info.st_mode & stat.S_IXUSR:
            raise SystemExit(1)
PY
}

# Validate schema-4 retained evidence and actual signing while the caller already holds the
# exclusive deployment lease. Calling `kist-dashboard --provenance-validate` here would attempt a
# nested shared flock and self-deadlock. `deployed_repo` remains the closure/Git/manifest validator;
# this function supplies the dashboard validator's pilot/enterprise evidence and signing checks.
validate_installed_provenance_exclusive() {
  deployed_repo >/dev/null || return 1
  validate_installed_dashboard || return 1
  provenance_projection=$(python_clean - "$INSTALL_HOME/bin/kist-current.manifest" \
    "$INSTALL_HOME/bin/kist-current.provenance.json" <<'PY'
import hashlib,json,os,stat,sys
manifest_path,evidence_path=sys.argv[1:]; uid=os.geteuid()
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
def stable(path,limit):
    before=os.lstat(path); identity=fp(before)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid!=uid or before.st_nlink!=1
            or stat.S_IMODE(before.st_mode)!=0o600 or before.st_size>limit):
        raise SystemExit(1)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        if fp(os.fstat(fd))!=identity: raise SystemExit(1)
        chunks=[]; remaining=before.st_size
        while remaining:
            block=os.read(fd,min(1024*1024,remaining))
            if not block: raise SystemExit(1)
            chunks.append(block); remaining-=len(block)
        if os.read(fd,1) or fp(os.fstat(fd))!=identity or fp(os.lstat(path))!=identity:
            raise SystemExit(1)
        return b"".join(chunks)
    finally: os.close(fd)
manifest_raw=stable(manifest_path,262144); evidence=stable(evidence_path,64*1024*1024)
try: text=manifest_raw.decode("utf-8")
except UnicodeDecodeError: raise SystemExit(1)
if not text.endswith("\n") or "\r" in text: raise SystemExit(1)
fields={}
for line in text.splitlines():
    if not line or ":" not in line: raise SystemExit(1)
    key,value=line.split(":",1); key=key.strip().lower(); value=value.strip()
    if not key or not value or key in fields: raise SystemExit(1)
    fields[key]=value
if fields.get("schema")!="4" or fields.get("deployment-assurance") not in {"pilot","enterprise"}:
    raise SystemExit(1)
if hashlib.sha256(evidence).hexdigest()!=fields.get("deployment-evidence-sha256"):
    raise SystemExit(1)
if fields["deployment-assurance"]=="pilot":
    try: pilot=json.loads(evidence)
    except (UnicodeDecodeError,json.JSONDecodeError): raise SystemExit(1)
    expected={"schema":1,"assurance":"pilot","provenance_kind":"local-candidate",
              "product_version":fields.get("product-version"),
              "source_state_sha256":fields.get("source-state-sha256"),
              "unsigned_release_sha256":fields.get("unsigned-release-sha256"),
              "signed_installed_sha256":fields.get("signed-installed-sha256")}
    if type(pilot) is not dict or pilot!=expected or (
            json.dumps(pilot,sort_keys=True,separators=(",",":"),ensure_ascii=True)+"\n").encode()!=evidence:
        raise SystemExit(1)
elif fields.get("enterprise-evidence-sha256")!=fields.get("deployment-evidence-sha256"):
    raise SystemExit(1)
for key in ["deployment-assurance","signing-type","signing-identity","notarization-status"]:
    value=fields.get(key)
    if not value or "\n" in value or "\r" in value: raise SystemExit(1)
    print(key+"="+value)
PY
  ) || return 1
  projection_value() {
    printf '%s\n' "$provenance_projection" | /usr/bin/awk -F= -v key="$1" \
      '$1==key {if(seen++)exit 2;value=substr($0,length(key)+2)} END{if(seen!=1||value=="")exit 3;print value}'
  }
  installed_assurance=$(projection_value deployment-assurance) || return 1
  expected_signing_type=$(projection_value signing-type) || return 1
  expected_signing_identity=$(projection_value signing-identity) || return 1
  expected_notarization=$(projection_value notarization-status) || return 1
  if [ "$installed_assurance" = enterprise ]; then
    enterprise_evidence_evaluate "$INSTALL_HOME/bin/kist-current.provenance.json" \
      "$INSTALL_HOME/bin/kist-current.manifest" "$INSTALL_HOME/bin/kist-current" >/dev/null \
      || return 1
  fi
  actual_signing=$(signing_state "$INSTALL_HOME/bin/kist-current") || return 1
  actual_signing_type=$(printf '%s\n' "$actual_signing" | /usr/bin/awk -F= \
    '$1=="signing-type"{if(seen++)exit 2;value=substr($0,14)} END{if(seen!=1)exit 3;print value}') \
    || return 1
  actual_signing_identity=$(printf '%s\n' "$actual_signing" | /usr/bin/awk -F= \
    '$1=="signing-identity"{if(seen++)exit 2;value=substr($0,18)} END{if(seen!=1)exit 3;print value}') \
    || return 1
  actual_notarization=$(printf '%s\n' "$actual_signing" | /usr/bin/awk -F= \
    '$1=="notarization-status"{if(seen++)exit 2;value=substr($0,21)} END{if(seen!=1)exit 3;print value}') \
    || return 1
  [ "$actual_signing_type" = "$expected_signing_type" ] \
    && [ "$actual_signing_identity" = "$expected_signing_identity" ] \
    && [ "$actual_notarization" = "$expected_notarization" ] || return 1
  if [ "$installed_assurance" = enterprise ]; then
    [ "$actual_signing_type" = developer-id ] && [ "$actual_notarization" = accepted ] || return 1
  fi
}

# The rebuilding shell owns descriptor 9 and therefore owns the BSD flock itself.  A short,
# trusted Python process validates the path and applies flock to the inherited open-file
# description; the lock remains held by this shell after that process exits.  Candidate code and
# hooks never inherit descriptor 9.
DEPLOY_LEASE_ACTIVE=0
DEPLOY_LEASE_MODE=
DEPLOY_LEASE_IDENTITY=
DEPLOY_LEASE_PATH="$INSTALL_HOME/bin/.kist-deployment.lock"

lease_python() {
  /usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" LANG=C LC_ALL=C \
    TMPDIR=/private/tmp PYTHONNOUSERSITE=1 "$PYTHON" -I "$@"
}

prepare_deployment_lease_path() {
  lease_python - "$DEPLOY_LEASE_PATH" <<'PY'
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

deployment_lease_fd_operation() {
  lease_action=$1
  lease_mode=$2
  lease_expected=${3-}
  lease_python - "$lease_action" "$lease_mode" "$DEPLOY_LEASE_PATH" \
    "$lease_expected" <<'PY'
import fcntl,os,stat,sys,time
action,mode,path,expected=sys.argv[1:]; uid=os.geteuid(); fd=9
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
def dfp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid)
def lock_fp(value):
    return (value.st_dev,value.st_ino)
def valid_file(value):
    return (stat.S_ISREG(value.st_mode) and value.st_uid==uid and value.st_nlink==1
            and stat.S_IMODE(value.st_mode)==0o600)
parent=os.path.dirname(path); leaf=os.path.basename(path)
if action not in {"acquire","assert"} or mode not in {"shared","exclusive"}:
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
            deadline=time.monotonic()+120.0
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

deployment_lease_alive() {
  [ "$DEPLOY_LEASE_ACTIVE" -eq 1 ] \
    && deployment_lease_fd_operation assert "$DEPLOY_LEASE_MODE" \
      "$DEPLOY_LEASE_IDENTITY" >/dev/null
}
require_deployment_lease() {
  required_mode=${1-}
  [ "$DEPLOY_LEASE_ACTIVE" -eq 1 ] || die "deployment lease is not active"
  [ -z "$required_mode" ] || [ "$DEPLOY_LEASE_MODE" = "$required_mode" ] \
    || die "deployment $required_mode lease is not active"
  deployment_lease_alive || die "deployment lease descriptor is not held by this process"
}
acquire_deployment_lease() {
  lease_mode=$1
  [ "$DEPLOY_LEASE_ACTIVE" -eq 0 ] || die "deployment lease is already active"
  case "$lease_mode" in shared|exclusive) ;; *) die "invalid deployment lease mode" ;; esac
  prepare_deployment_lease_path || die "deployment lease path is unsafe"
  if ! exec 9< "$DEPLOY_LEASE_PATH"; then
    die "cannot open deployment lease"
  fi
  if ! lease_identity=$(deployment_lease_fd_operation acquire "$lease_mode"); then
    exec 9>&-
    die "timed out or failed to acquire the deployment $lease_mode lease"
  fi
  case "$lease_identity" in
    ""|*[!0-9:]*|:*|*:|*:*:*)
      exec 9>&-; die "deployment lease returned an invalid identity" ;;
    *:*) ;;
    *) exec 9>&-; die "deployment lease returned an invalid identity" ;;
  esac
  DEPLOY_LEASE_ACTIVE=1
  DEPLOY_LEASE_MODE=$lease_mode
  DEPLOY_LEASE_IDENTITY=$lease_identity
  deployment_lease_alive || {
    exec 9>&-
    DEPLOY_LEASE_ACTIVE=0
    DEPLOY_LEASE_MODE=
    DEPLOY_LEASE_IDENTITY=
    die "deployment lease descriptor was lost during acquisition"
  }
}
abandon_deployment_lease() {
  [ "$DEPLOY_LEASE_ACTIVE" -eq 1 ] || return 0
  exec 9>&-
  DEPLOY_LEASE_ACTIVE=0
  DEPLOY_LEASE_MODE=
  DEPLOY_LEASE_IDENTITY=
}
ensure_exclusive_recovery_lease() {
  if [ "$DEPLOY_LEASE_ACTIVE" -eq 1 ] && [ "$DEPLOY_LEASE_MODE" = exclusive ] \
     && deployment_lease_alive; then
    return 0
  fi
  abandon_deployment_lease
  acquire_deployment_lease exclusive
  deployment_lease_alive
}
release_deployment_lease() {
  [ "$DEPLOY_LEASE_ACTIVE" -eq 1 ] || return 0
  lease_release_status=0
  deployment_lease_alive || lease_release_status=1
  exec 9>&-
  DEPLOY_LEASE_ACTIVE=0
  DEPLOY_LEASE_MODE=
  DEPLOY_LEASE_IDENTITY=
  return "$lease_release_status"
}

