# Same schema/digest semantics as Swift and kist-rebuild. The helper reads through O_NOFOLLOW
# descriptors, rejects ACL/mode/owner/type drift, and binds executable Python plus served assets.
PROVENANCE_OUTPUT="$(resource_python "$INSTALL_HOME" "$EVALUATE" "$EVAL_BINARY" "$EVAL_WRAPPER" \
  "$EVAL_DASHBOARD" "$EVAL_REBUILD" "$EVAL_SAFE_REBUILD" "$EVAL_CLOSURE_VERSION" \
  "$REQUIRE_ENTERPRISE" "$EVAL_RESOURCE_CODE" "$EVAL_RESOURCE_WEB" <<'PY'
import ctypes, errno, hashlib, json, os, stat, subprocess, sys
HOME=os.path.realpath(sys.argv[1]); EVALUATE=sys.argv[2]=="1"
OVERRIDES={"bin/kist-current":sys.argv[3],"bin/kist":sys.argv[4],
           "bin/kist-dashboard":sys.argv[5],"bin/kist-rebuild":sys.argv[6],
           "bin/kist-safe-rebuild.sh":sys.argv[7]}
EVAL_CLOSURE_VERSION=sys.argv[8]; REQUIRE_ENTERPRISE=sys.argv[9]=="1"
for alias, physical in zip(RESOURCE_FILES, sys.argv[10:12]):
    OVERRIDES["bin/"+RESOURCE_ROOT+"/"+RESOURCE_FILES[alias]]=physical
UID=os.geteuid(); MAX_FILE=512*1024*1024
MAX_TOTAL=1024*1024*1024; MAX_PATHS=4*1024*1024; MAX_ENTRIES=25000
SKIP={".git",".pytest_cache"}
IMPORTABLE=(".py",".pyw",".pyi",".pth",".so",".dylib",".bundle",".pyd",".zip",".egg",".whl",".pyz")
EXECUTABLE_SUFFIXES=(".sh",".bash",".zsh",".swift",".js",".mjs",".cjs",".pl",".rb")
CONFIG_SUFFIXES=(".toml",".yaml",".yml",".ini",".cfg",".plist")
CONFIG_NAMES={"Pipfile","requirements.txt","constraints.txt"}
def fp(s): return (s.st_dev,s.st_ino,s.st_mode,s.st_uid,s.st_size,s.st_nlink,s.st_mtime_ns,s.st_ctime_ns)
libc=ctypes.CDLL(None,use_errno=True); libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]; libc.acl_get_fd_np.restype=ctypes.c_void_p; libc.acl_free.argtypes=[ctypes.c_void_p]
def acl(fd):
    ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
    if value: libc.acl_free(value); return True
    error=ctypes.get_errno()
    if error in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
    raise OSError(error,os.strerror(error))
def pins(relative):
    target=os.path.join(HOME,relative) if relative else HOME
    hc=[x for x in HOME.split("/") if x]; tc=[x for x in target.split("/") if x]
    if tc[:len(hc)]!=hc: raise RuntimeError("escape")
    out=[]; fd=os.open("/",os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW); out.append((fd,None,fp(os.fstat(fd))))
    cur=""
    try:
        for name in tc:
            st=os.stat(name,dir_fd=fd,follow_symlinks=False); cur += "/"+name
            if not stat.S_ISDIR(st.st_mode) or st.st_mode&0o022: raise RuntimeError("directory mode")
            below=cur==HOME or cur.startswith(HOME+"/")
            if (below and st.st_uid!=UID) or (not below and st.st_uid not in {0,UID}): raise RuntimeError("directory owner")
            child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            if fp(os.fstat(child))!=fp(st) or (below and cur!=HOME and acl(child)): os.close(child); raise RuntimeError("directory race/acl")
            out.append((child,name,fp(st))); fd=child
        return out
    except Exception:
        for item in reversed(out): os.close(item[0])
        raise
def stable(ps):
    for i,(fd,name,identity) in enumerate(ps):
        if fp(os.fstat(fd))!=identity: return False
        if i and fp(os.stat(name,dir_fd=ps[i-1][0],follow_symlinks=False))!=identity: return False
    return True
budget=[0,0]
def reserve(logical,size):
    path=logical.encode()
    if size>MAX_TOTAL-budget[0] or len(path)>MAX_PATHS-budget[1]: raise RuntimeError("aggregate bound")
    budget[0]+=size; budget[1]+=len(path)
def read_leaf(relative, executable=False, limit=MAX_FILE, logical=None, digest_only=False):
    parts=relative.split("/"); ps=pins("/".join(parts[:-1])); parent=ps[-1][0]; leaf=parts[-1]
    try:
        st=os.stat(leaf,dir_fd=parent,follow_symlinks=False); ident=fp(st)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid!=UID or st.st_nlink!=1
                or st.st_mode&0o022 or st.st_size>limit): raise RuntimeError("leaf trust")
        if executable and not st.st_mode&stat.S_IXUSR: raise RuntimeError("owner execute")
        if logical is not None: reserve(logical,st.st_size)
        fd=os.open(leaf,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=parent)
        try:
            if fp(os.fstat(fd))!=ident or acl(fd): raise RuntimeError("leaf race/acl")
            chunks=[]; digest=hashlib.sha256() if digest_only else None; total=0
            while True:
                block=os.read(fd,min(1024*1024,limit-total+1))
                if not block: break
                total+=len(block)
                if total>limit: raise RuntimeError("leaf too large")
                if digest is not None: digest.update(block)
                else: chunks.append(block)
            if fp(os.fstat(fd))!=ident or fp(os.stat(leaf,dir_fd=parent,follow_symlinks=False))!=ident or not stable(ps): raise RuntimeError("leaf changed")
            return (digest.digest() if digest is not None else b"".join(chunks)),stat.S_IMODE(st.st_mode),st.st_size
        finally: os.close(fd)
    finally:
        for item in reversed(ps): os.close(item[0])
def cortex():
    ps=pins(".kist/cortex"); rootfd=ps[-1][0]; result=[]; visited=0
    def walk(fd,prefix):
        nonlocal visited
        initial=fp(os.fstat(fd)); observed=[]
        with os.scandir(os.dup(fd)) as scan:
            names=sorted((e.name for e in scan),key=lambda x:x.encode())
        for name in names:
            rel=f"{prefix}/{name}" if prefix else name; visited+=1
            if visited>250000 or len(rel.encode())>16384: raise RuntimeError("inventory bound")
            st=os.stat(name,dir_fd=fd,follow_symlinks=False); ident=fp(st); observed.append((name,ident))
            if name=="__pycache__" or rel.lower().endswith((".pyc",".pyo")): raise RuntimeError("unbound bytecode")
            if name in SKIP:
                if not stat.S_ISDIR(st.st_mode): raise RuntimeError("cache type")
                continue
            if stat.S_ISDIR(st.st_mode):
                if st.st_uid!=UID or st.st_mode&0o022: raise RuntimeError("cortex directory trust")
                child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                try:
                    if fp(os.fstat(child))!=ident or acl(child): raise RuntimeError("cortex directory race/acl")
                    walk(child,rel)
                    if fp(os.fstat(child))!=ident or fp(os.stat(name,dir_fd=fd,follow_symlinks=False))!=ident: raise RuntimeError("cortex directory changed")
                finally: os.close(child)
            elif stat.S_ISREG(st.st_mode):
                lower=rel.lower(); executable=bool(st.st_mode&(stat.S_IXUSR|stat.S_IXGRP|stat.S_IXOTH))
                selected=(lower.endswith(IMPORTABLE) or rel.startswith("live/assets/")
                          or name in CONFIG_NAMES or lower.endswith(CONFIG_SUFFIXES))
                if executable and not selected:
                    if not lower.endswith(EXECUTABLE_SUFFIXES): raise RuntimeError("unrecognized executable cortex payload")
                    selected=True
                if not selected: continue
                if (len(result)>=MAX_ENTRIES-5 or st.st_uid!=UID or st.st_nlink!=1
                        or st.st_mode&0o022 or st.st_size>MAX_FILE): raise RuntimeError("cortex leaf trust")
                logical=f".kist/cortex/{rel}"; reserve(logical,st.st_size)
                child=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
                try:
                    if fp(os.fstat(child))!=ident or acl(child): raise RuntimeError("cortex leaf race/acl")
                    digest=hashlib.sha256(); remaining=st.st_size
                    while remaining:
                        block=os.read(child,min(1024*1024,remaining))
                        if not block: raise RuntimeError("cortex leaf short read")
                        digest.update(block); remaining-=len(block)
                    if os.read(child,1) or fp(os.fstat(child))!=ident or fp(os.stat(name,dir_fd=fd,follow_symlinks=False))!=ident: raise RuntimeError("cortex leaf changed")
                    result.append((logical,digest.digest(),stat.S_IMODE(st.st_mode),st.st_size))
                finally: os.close(child)
            else: raise RuntimeError("cortex special/symlink")
        if fp(os.fstat(fd))!=initial: raise RuntimeError("cortex inventory changed")
        for name,ident in observed:
            if fp(os.stat(name,dir_fd=fd,follow_symlinks=False))!=ident: raise RuntimeError("cortex name changed")
    try:
        walk(rootfd,"")
        if not stable(ps): raise RuntimeError("cortex ancestry changed")
        return result
    finally:
        for item in reversed(ps): os.close(item[0])
schema3_required={"schema","stamp","deployed","worktree","branch","commit","remote-origin-sha256","repository-id","source-dirty","source-state-sha256","binary-sha256","wrapper-sha256","dashboard-launcher-sha256","rebuild-sha256","dashboard-runtime-sha256","artifact-closure-sha256","artifact-closure-count","test-evidence"}
schema4_extras={"deployment-assurance","provenance-kind","unsigned-release-sha256","signed-installed-sha256","signing-type","signing-identity","notarization-status","notarization-submission-id","notarization-package-sha256","deployment-evidence-sha256","product-version"}
schema4_legacy_base=schema3_required|schema4_extras
# The v3 aggregate closure remains exactly the transactionally restorable release payload.
# Dashboard runtime and cortex code/assets are operational state, not archive payloads, but new v3
# manifests bind the exact runtime plus selected cortex tree through separate digests/count. The
# older v3 shape remains readable for bootstrap and rollback compatibility and still receives the
# full trust walk below.
schema4_v3_legacy_base=(schema3_required-{"dashboard-runtime-sha256"})|schema4_extras|{"safe-rebuild-sha256"}
schema4_v3_operational={"dashboard-runtime-sha256","dashboard-cortex-sha256","dashboard-cortex-count"}
schema4_v3_base=schema4_v3_legacy_base|schema4_v3_operational
resource_fields=set(RESOURCE_KEYS.values())
schema4_enterprise={"candidate-manifest-sha256","full-suite-evidence-sha256","full-suite-test-count","full-suite-failures","full-suite-errors","five-canary-evidence-sha256","five-canary-count","five-canary-failures","sbom-sha256","sbom-format","enterprise-evidence-sha256"}
fields={}; stamp=""; schema=""; closure_version=0; operational_bound=False
if EVALUATE:
    if EVAL_CLOSURE_VERSION not in {"2","3","4"}: raise SystemExit(1)
    closure_version=int(EVAL_CLOSURE_VERSION)
else:
    stamp=read_leaf("bin/.kist-build",False,16384)[0].decode()
    manifest=read_leaf("bin/kist-current.manifest",False,262144)[0].decode()
    if not stamp.endswith("\n") or "\n" in stamp[:-1] or "\r" in stamp: raise SystemExit(1)
    stamp=stamp[:-1]
    for raw in manifest.splitlines():
        if not raw or ":" not in raw: raise SystemExit(1)
        k,v=raw.split(":",1); k=k.strip().lower(); v=v.strip()
        if not k or not v or k in fields: raise SystemExit(1)
        fields[k]=v
    schema=fields.get("schema")
    assurance=fields.get("deployment-assurance")
    if schema=="3":
        required=schema3_required; closure_version=2
    elif schema=="4" and assurance in {"pilot","enterprise"}:
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
        if assurance=="enterprise": required=required|schema4_enterprise
    else:
        raise SystemExit(1)
    if set(fields)!=required or fields["stamp"]!=stamp: raise SystemExit(1)

fixed_v2=[("bin/kist-current",True),("bin/kist",True),("bin/kist-dashboard",True),
          ("bin/kist-rebuild",True),(".kist/scripts/kist_runtime.py",True)]
fixed_v3=[("bin/kist-current",True),("bin/kist",True),("bin/kist-dashboard",True),
          ("bin/kist-rebuild",True),("bin/kist-safe-rebuild.sh",True)]
fixed=fixed_v3 if closure_version>=3 else fixed_v2
if closure_version==4:
    fixed=fixed+[("bin/"+RESOURCE_ROOT+"/"+relative,False) for relative in RESOURCE_FILES.values()]
    if not EVALUATE or all(OVERRIDES[logical]==os.path.join(HOME,logical)
                           for logical,_ in fixed[5:]):
        resource_tree(os.path.join(HOME,"bin",RESOURCE_ROOT))
entries=[]; hashes={}
for logical,exe in fixed:
    physical=OVERRIDES.get(logical) if EVALUATE else ""
    selected=logical
    if physical:
        canonical=os.path.realpath(physical)
        if canonical!=physical or not canonical.startswith(HOME+"/"): raise SystemExit(1)
        selected=os.path.relpath(canonical,HOME)
    digest,mode,size=read_leaf(selected,exe,logical=logical,digest_only=True)
    entries.append((logical,digest,mode,size)); hashes[logical]=digest.hex()

cortex_entries=cortex()
runtime_digest=None
if closure_version==2:
    entries += cortex_entries
    runtime_digest=hashes[".kist/scripts/kist_runtime.py"]
else:
    # Runtime remains independently trust-validated on every launch/validation. Its bytes are then
    # compiled from, and retained through, the validated descriptor below.
    runtime_digest=read_leaf(".kist/scripts/kist_runtime.py",True,digest_only=True)[0].hex()
entries.sort(key=lambda x:x[0].encode())
closure=hashlib.sha256()
closure.update({2:b"kist-artifact-closure-v2\0",3:b"kist-artifact-closure-v3\0",
                4:b"kist-artifact-closure-v4\0"}[closure_version])
for logical,digest,mode,size in entries:
    p=logical.encode()
    closure.update(len(p).to_bytes(8,"big")); closure.update(p)
    closure.update(mode.to_bytes(4,"big")); closure.update(size.to_bytes(8,"big")); closure.update(digest)
cortex_entries.sort(key=lambda x:x[0].encode())
cortex_digest=hashlib.sha256(b"kist-dashboard-cortex-v1\0")
for logical,digest,mode,size in cortex_entries:
    p=logical.encode()
    cortex_digest.update(len(p).to_bytes(8,"big")); cortex_digest.update(p)
    cortex_digest.update(mode.to_bytes(4,"big")); cortex_digest.update(size.to_bytes(8,"big")); cortex_digest.update(digest)

if EVALUATE:
    print("binary-sha256="+hashes["bin/kist-current"])
    print("wrapper-sha256="+hashes["bin/kist"])
    print("dashboard-launcher-sha256="+hashes["bin/kist-dashboard"])
    print("rebuild-sha256="+hashes["bin/kist-rebuild"])
    if closure_version>=3:
        print("safe-rebuild-sha256="+hashes["bin/kist-safe-rebuild.sh"])
        print("dashboard-runtime-sha256="+runtime_digest)
        print("dashboard-cortex-sha256="+cortex_digest.hexdigest())
        print("dashboard-cortex-count="+str(len(cortex_entries)))
    else:
        print("dashboard-runtime-sha256="+hashes[".kist/scripts/kist_runtime.py"])
    if closure_version==4:
        for alias, key in RESOURCE_KEYS.items():
            print(key+"="+hashes["bin/"+RESOURCE_ROOT+"/"+RESOURCE_FILES[alias]])
    print("artifact-closure-sha256="+closure.hexdigest())
    print("artifact-closure-count="+str(len(entries)))
    raise SystemExit(0)

stamp_parts=stamp.split(" · ",3)
def valid_hex(value,minimum=64,maximum=64):
    return minimum<=len(value)<=maximum and all(character in "0123456789abcdefABCDEF" for character in value)
if len(stamp_parts)!=4 or not all(part.strip() for part in stamp_parts) or not valid_hex(stamp_parts[0],7,64): raise SystemExit(1)
if not os.path.isabs(stamp_parts[3]) or fields["deployed"]!=stamp_parts[2] or fields["worktree"]!=stamp_parts[3] or fields["branch"]!=stamp_parts[1]: raise SystemExit(1)
if os.path.realpath(fields["worktree"])!=fields["worktree"] or not os.path.isdir(fields["worktree"]): raise SystemExit(1)
if not valid_hex(fields["commit"],40,64) or not fields["commit"].lower().startswith(stamp_parts[0].lower()): raise SystemExit(1)
hash_fields=["remote-origin-sha256","repository-id","source-state-sha256","binary-sha256",
             "wrapper-sha256","dashboard-launcher-sha256","rebuild-sha256",
             "artifact-closure-sha256"]
hash_fields.append("safe-rebuild-sha256" if closure_version>=3 else "dashboard-runtime-sha256")
if closure_version==4: hash_fields.extend(resource_fields)
if operational_bound: hash_fields.extend(["dashboard-runtime-sha256","dashboard-cortex-sha256"])
for key in hash_fields:
    if not valid_hex(fields[key]): raise SystemExit(1)
if fields["source-dirty"] not in {"yes","no"} or fields["test-evidence"].lower()=="yes": raise SystemExit(1)
try: closure_count=int(fields["artifact-closure-count"])
except ValueError: raise SystemExit(1)
if closure_count<=0 or str(closure_count)!=fields["artifact-closure-count"] or closure_count!=len(entries): raise SystemExit(1)
if operational_bound:
    try: cortex_count=int(fields["dashboard-cortex-count"])
    except ValueError: raise SystemExit(1)
    if cortex_count<0 or str(cortex_count)!=fields["dashboard-cortex-count"] or cortex_count!=len(cortex_entries): raise SystemExit(1)
checks={"binary-sha256":hashes["bin/kist-current"],"wrapper-sha256":hashes["bin/kist"],
        "dashboard-launcher-sha256":hashes["bin/kist-dashboard"],
        "rebuild-sha256":hashes["bin/kist-rebuild"],
        "artifact-closure-sha256":closure.hexdigest(),"artifact-closure-count":str(len(entries))}
if closure_version>=3:
    checks["safe-rebuild-sha256"]=hashes["bin/kist-safe-rebuild.sh"]
    if operational_bound:
        checks["dashboard-runtime-sha256"]=runtime_digest
        checks["dashboard-cortex-sha256"]=cortex_digest.hexdigest()
        checks["dashboard-cortex-count"]=str(len(cortex_entries))
else:
    checks["dashboard-runtime-sha256"]=hashes[".kist/scripts/kist_runtime.py"]
if closure_version==4:
    for alias,key in RESOURCE_KEYS.items():
        checks[key]=hashes["bin/"+RESOURCE_ROOT+"/"+RESOURCE_FILES[alias]]
if any(fields[k]!=v for k,v in checks.items()): raise SystemExit(1)
if schema=="4":
    import re
    semver=r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    if not re.fullmatch(semver,fields["product-version"]): raise SystemExit(1)
    for key in ["unsigned-release-sha256","signed-installed-sha256","deployment-evidence-sha256"]:
        if not valid_hex(fields[key]): raise SystemExit(1)
    if fields["signed-installed-sha256"]!=fields["binary-sha256"] or fields["provenance-kind"]!="local-candidate": raise SystemExit(1)
    if fields["signing-type"] not in {"ad-hoc","developer-id","other"} or fields["notarization-status"] not in {"accepted","not-accepted"}: raise SystemExit(1)
    if not fields["signing-identity"] or len(fields["signing-identity"])>512 or any(ord(c)<32 or ord(c)==127 for c in fields["signing-identity"]): raise SystemExit(1)
    if fields["notarization-status"]=="accepted":
        import re
        if not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",fields["notarization-submission-id"]) or not valid_hex(fields["notarization-package-sha256"]): raise SystemExit(1)
    elif fields["notarization-submission-id"]!="none" or fields["notarization-package-sha256"]!="none": raise SystemExit(1)
    evidence=read_leaf("bin/kist-current.provenance.json",False,64*1024*1024)[0]
    if hashlib.sha256(evidence).hexdigest()!=fields["deployment-evidence-sha256"]: raise SystemExit(1)
    if fields["deployment-assurance"]=="pilot":
        try: pilot=json.loads(evidence)
        except (UnicodeDecodeError,json.JSONDecodeError): raise SystemExit(1)
        if type(pilot) is not dict or set(pilot)!={"schema","assurance","provenance_kind","product_version","source_state_sha256","unsigned_release_sha256","signed_installed_sha256"}: raise SystemExit(1)
        if (json.dumps(pilot,sort_keys=True,separators=(",",":"),ensure_ascii=True)+"\n").encode()!=evidence: raise SystemExit(1)
        if pilot!={"schema":1,"assurance":"pilot","provenance_kind":"local-candidate","product_version":fields["product-version"],"source_state_sha256":fields["source-state-sha256"],"unsigned_release_sha256":fields["unsigned-release-sha256"],"signed_installed_sha256":fields["signed-installed-sha256"]}: raise SystemExit(1)
    else:
        if fields.get("enterprise-evidence-sha256")!=fields["deployment-evidence-sha256"] or fields.get("sbom-format")!="cyclonedx-1.7-json": raise SystemExit(1)
        validation=subprocess.run([os.path.join(HOME,"bin","kist-rebuild"),"--evidence-evaluate",os.path.join(HOME,"bin","kist-current.provenance.json"),os.path.join(HOME,"bin","kist-current.manifest"),os.path.join(HOME,"bin","kist-current")],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30)
        if validation.returncode or len(validation.stdout)>65536: raise SystemExit(1)
    signing=subprocess.run([os.path.join(HOME,"bin","kist-rebuild"),"--signing-evaluate",os.path.join(HOME,"bin","kist-current")],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30)
    if signing.returncode or len(signing.stdout)>4096: raise SystemExit(1)
    actual={}
    for line in signing.stdout.decode("utf-8").splitlines():
        key,sep,value=line.partition("=")
        if not sep or key in actual: raise SystemExit(1)
        actual[key]=value
    if actual!={"signing-type":fields["signing-type"],"signing-identity":fields["signing-identity"],"notarization-status":fields["notarization-status"]}: raise SystemExit(1)
    if fields["deployment-assurance"]=="enterprise" and (fields["signing-type"]!="developer-id" or fields["notarization-status"]!="accepted"): raise SystemExit(1)
if REQUIRE_ENTERPRISE and not (
    schema=="4" and closure_version>=3 and fields.get("deployment-assurance")=="enterprise"
): raise SystemExit(1)
if runtime_digest is None: raise SystemExit(1)
print("dashboard-runtime-sha256="+runtime_digest)
print("dashboard-cortex-sha256="+cortex_digest.hexdigest())
print("dashboard-cortex-count="+str(len(cortex_entries)))
print("artifact-closure-version="+str(closure_version))
print("artifact-closure-sha256="+closure.hexdigest())
print("deployment-assurance="+(fields.get("deployment-assurance") or "legacy-schema-3"))
PY
 )" || die 'deployment provenance validation failed'
if [[ "$EVALUATE" -eq 1 ]]; then
  # Bash's builtin printf can fail with EINTR while a caller captures the projection.
  # Python retries interrupted writes and flushes before success; all validation above
  # remains mandatory, and a failed output write must remain a failed evaluation.
  python_clean -c 'import sys; sys.stdout.write(sys.argv[1] + "\n"); sys.stdout.flush()' \
    "$PROVENANCE_OUTPUT" || die 'cannot emit validated deployment provenance'
  exit 0
fi
if [[ "${KIST_REBUILD_TESTING-}" == 1 \
      && "${KIST_DASHBOARD_TEST_CLOSE_DEPLOYMENT_LEASE_AFTER_VALIDATION-}" == 1 ]]; then
  [[ "$INSTALL_HOME" != /Users/lukekist ]] \
    || die 'dashboard lease failure hooks are forbidden for production'
  exec 9>&-
fi
assert_lease deployment
projection_value() {
  local projection="$1" key="$2"
  printf '%s\n' "$projection" | /usr/bin/awk -F= -v key="$key" '
    $1==key { if (seen++) exit 2; value=substr($0,length(key)+2) }
    END { if (seen!=1 || value=="") exit 3; print value }
  '
}
RUNTIME_SHA=$(projection_value "$PROVENANCE_OUTPUT" dashboard-runtime-sha256) \
  || die 'validated provenance omitted the exact runtime digest'
CORTEX_SHA=$(projection_value "$PROVENANCE_OUTPUT" dashboard-cortex-sha256) \
  || die 'validated provenance omitted the exact cortex digest'
CORTEX_COUNT=$(projection_value "$PROVENANCE_OUTPUT" dashboard-cortex-count) \
  || die 'validated provenance omitted the exact cortex count'
CLOSURE_VERSION=$(projection_value "$PROVENANCE_OUTPUT" artifact-closure-version) \
  || die 'validated provenance omitted the closure version'
CLOSURE_SHA=$(projection_value "$PROVENANCE_OUTPUT" artifact-closure-sha256) \
  || die 'validated provenance omitted the closure digest'
[[ "$RUNTIME_SHA" =~ ^[a-f0-9]{64}$ && "$CORTEX_SHA" =~ ^[a-f0-9]{64}$ \
   && "$CORTEX_COUNT" =~ ^(0|[1-9][0-9]*)$ && "$CLOSURE_VERSION" =~ ^[234]$ \
   && "$CLOSURE_SHA" =~ ^[a-f0-9]{64}$ ]] \
  || die 'validated provenance returned a malformed operational projection'
