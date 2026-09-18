# kist-release-registry-v1
# Retain explicitly approved, exact deployment transaction sets and prepare a CAS-bound rollback.
# This registry is an owner-local recovery control, not a remote/WORM trust root: the full current
# release digest approves an archive, and the full plan digest approves a rollback.
release_registry_control() {
  registry_action=$1
  shift
  case "$registry_action" in
    status|list|plan) require_deployment_lease ;;
    archive|stage) require_deployment_lease exclusive ;;
    *) die "unknown release registry action" ;;
  esac
  resource_python "$INSTALL_HOME" "$registry_action" "$@" <<'PY'
import datetime,hashlib,json,os,re,secrets,stat,sys,time

home,action,*arguments=sys.argv[1:]
home=os.path.realpath(home); uid=os.geteuid(); bindir=os.path.join(home,"bin")
registry=os.path.join(home,".kist","release-registry"); releases=os.path.join(registry,"releases")
legacy_targets=["kist-current","kist","kist-dashboard","kist-rebuild",
                "kist-current.manifest",".kist-build","kist-current.provenance.json"]
v3_targets=["kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh",
            "kist-current.manifest",".kist-build","kist-current.provenance.json"]
v4_targets=v3_targets+list(RESOURCE_FILES)
known_targets=set(legacy_targets)|set(v4_targets)
executables={"kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh"}
MAX_FILE=512*1024*1024; MAX_TOTAL=1024*1024*1024; MAX_RELEASES=32
HEX=re.compile(r"[0-9a-f]{64}")
STAGING=re.compile(r"\.release-staging\.[0-9a-f]{32}")

def fail(message):
    print("release registry: "+message,file=sys.stderr)
    raise SystemExit(1)
def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True)+"\n").encode()
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
def write_all(fd,data):
    offset=0
    while offset<len(data):
        written=os.write(fd,data[offset:])
        if written<=0: fail("short write")
        offset+=written
def secure_directory(path,exact_private=False):
    try: value=os.lstat(path)
    except FileNotFoundError: fail("required directory is missing")
    if (not stat.S_ISDIR(value.st_mode) or value.st_uid!=uid or
            value.st_mode&0o022 or os.path.realpath(path)!=path):
        fail("directory ownership, mode, or ancestry is untrusted")
    if exact_private and stat.S_IMODE(value.st_mode)!=0o700:
        fail("registry directory is not mode 0700")
    return value
def make_private(path):
    try:
        os.mkdir(path,0o700)
        os.chmod(path,0o700)
    except FileExistsError:
        pass
    secure_directory(path,True)
def stable_read(path,limit,expected_mode=None,executable=None):
    try: before=os.lstat(path)
    except FileNotFoundError: fail("required file is missing: "+os.path.basename(path))
    mode=stat.S_IMODE(before.st_mode)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid!=uid or before.st_nlink!=1
            or before.st_mode&0o022 or before.st_size>limit):
        fail("file ownership, type, link count, mode, or size is untrusted: "+os.path.basename(path))
    if expected_mode is not None and mode!=expected_mode:
        fail("file mode is not canonical: "+os.path.basename(path))
    if executable is True and not before.st_mode&stat.S_IXUSR:
        fail("expected executable is not owner-executable: "+os.path.basename(path))
    if executable is False and mode!=0o600:
        fail("deployment metadata is not mode 0600: "+os.path.basename(path))
    identity=fp(before)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        if fp(os.fstat(fd))!=identity: fail("file changed before read")
        chunks=[]; remaining=before.st_size
        while remaining:
            block=os.read(fd,min(1024*1024,remaining))
            if not block: fail("short read")
            chunks.append(block); remaining-=len(block)
        if os.read(fd,1) or fp(os.fstat(fd))!=identity or fp(os.lstat(path))!=identity:
            fail("file changed during read")
        return b"".join(chunks),mode
    finally: os.close(fd)
def parse_manifest(raw):
    try: text=raw.decode("utf-8")
    except UnicodeDecodeError: fail("manifest is not UTF-8")
    if not text.endswith("\n") or "\r" in text: fail("manifest is not canonical text")
    fields={}
    for line in text.splitlines():
        if not line or ":" not in line: fail("manifest line is malformed")
        key,value=line.split(":",1); key=key.strip().lower(); value=value.strip()
        if not key or not value or key in fields: fail("manifest field is malformed")
        fields[key]=value
    required={"schema","stamp","commit","deployment-assurance","product-version",
              "artifact-closure-sha256","source-state-sha256"}
    if not required<=set(fields) or fields["schema"]!="4":
        fail("only coherent schema-4 deployments may be archived")
    if fields["deployment-assurance"] not in {"pilot","enterprise"}:
        fail("manifest assurance is invalid")
    for key in ["commit","artifact-closure-sha256","source-state-sha256"]:
        if not HEX.fullmatch(fields[key]) and not (key=="commit" and re.fullmatch(r"[0-9a-fA-F]{40,64}",fields[key])):
            fail("manifest identity is malformed")
    operational={"dashboard-runtime-sha256","dashboard-cortex-sha256","dashboard-cortex-count"}
    if "safe-rebuild-sha256" in fields:
        if operational&set(fields) and not operational<=set(fields):
            fail("v3 operational binding is incomplete")
        if operational<=set(fields):
            if (not HEX.fullmatch(fields["dashboard-runtime-sha256"])
                    or not HEX.fullmatch(fields["dashboard-cortex-sha256"])):
                fail("v3 operational digest is malformed")
            count=fields["dashboard-cortex-count"]
            if not count.isdigit() or str(int(count))!=count:
                fail("v3 cortex count is malformed")
    elif {"dashboard-cortex-sha256","dashboard-cortex-count"}&set(fields):
        fail("legacy manifest carries v3 cortex fields")
    resource_fields=set(RESOURCE_KEYS.values())
    if resource_fields&set(fields):
        if not resource_fields|operational|{"safe-rebuild-sha256"} <= set(fields):
            fail("resource binding is incomplete")
        if any(not HEX.fullmatch(fields[key]) for key in resource_fields):
            fail("resource digest is malformed")
    return fields
def release_digest(files):
    digest=hashlib.sha256(b"kist-release-registry-v1\0")
    for item in files:
        name=item["name"].encode()
        digest.update(len(name).to_bytes(8,"big")); digest.update(name)
        digest.update(item["mode"].to_bytes(4,"big"))
        digest.update(item["bytes"].to_bytes(8,"big"))
        digest.update(bytes.fromhex(item["sha256"]))
    return digest.hexdigest()
def targets_for_names(names):
    if names==legacy_targets: return legacy_targets
    if names==v3_targets: return v3_targets
    if names==v4_targets: return v4_targets
    fail("release file ordering is invalid")
def rollback_semantics(targets):
    if targets==v4_targets: return "exact-v4-with-resources"
    if targets==v3_targets: return "best-effort-v3-resources-not-archived"
    return "best-effort-legacy-non-self-contained"
def current_inventory(include_payload=False):
    secure_directory(home); secure_directory(bindir)
    manifest_raw=stable_read(os.path.join(bindir,"kist-current.manifest"),262144,
                             executable=False)[0]
    manifest=parse_manifest(manifest_raw)
    targets=v3_targets if "safe-rebuild-sha256" in manifest else legacy_targets
    if set(RESOURCE_KEYS.values())<=set(manifest):
        targets=v4_targets
        resource_tree(os.path.join(bindir,RESOURCE_ROOT))
    files=[]; payloads={}; total=0
    for name in targets:
        if name in RESOURCE_FILES:
            raw,mode=resource_read(resource_destination(bindir,name))
            if hashlib.sha256(raw).hexdigest()!=manifest[RESOURCE_KEYS[name]]:
                fail("resource changed during release inventory")
        else:
            raw,mode=stable_read(os.path.join(bindir,name),MAX_FILE,
                                 executable=True if name in executables else False)
        total+=len(raw)
        if total>MAX_TOTAL: fail("deployment transaction set exceeds aggregate bound")
        files.append({"bytes":len(raw),"mode":mode,"name":name,
                      "sha256":hashlib.sha256(raw).hexdigest()})
        if include_payload: payloads[name]=raw
    if include_payload and payloads["kist-current.manifest"]!=manifest_raw:
        fail("manifest changed during release inventory")
    identifier=release_digest(files)
    return identifier,files,payloads,manifest
def open_registry(create=False):
    secure_directory(home)
    kist=os.path.join(home,".kist")
    secure_directory(kist)
    if create:
        make_private(registry); make_private(releases)
    elif not os.path.lexists(registry):
        return False
    secure_directory(registry,True); secure_directory(releases,True)
    if set(os.listdir(registry))!={"releases"}: fail("registry contains unknown entries")
    return True
def release_names():
    if not open_registry(False): return []
    result=[]
    for name in os.listdir(releases):
        if STAGING.fullmatch(name):
            value=os.lstat(os.path.join(releases,name))
            if not stat.S_ISDIR(value.st_mode) or value.st_uid!=uid or stat.S_IMODE(value.st_mode)!=0o700:
                fail("archive staging entry is untrusted")
            continue
        if not re.fullmatch(r"release-[0-9a-f]{64}",name):
            fail("release registry contains an unknown entry")
        result.append(name)
    return sorted(result)
def cleanup_archive_staging():
    # Archive runs under the exclusive deployment lease. Remove only the exact private shape this
    # implementation can leave behind; an unknown name, symlink, or special file remains fail-closed.
    for name in os.listdir(releases):
        if not STAGING.fullmatch(name): continue
        directory=os.path.join(releases,name); secure_directory(directory,True)
        entries=set(os.listdir(directory))
        if not entries<= {"files","record.json"}: fail("archive staging contains unknown entries")
        record_path=os.path.join(directory,"record.json")
        if "record.json" in entries:
            value=os.lstat(record_path)
            if (not stat.S_ISREG(value.st_mode) or value.st_uid!=uid or value.st_nlink!=1
                    or value.st_mode&0o022): fail("archive staging record is untrusted")
            os.unlink(record_path)
        files_dir=os.path.join(directory,"files")
        if "files" in entries:
            secure_directory(files_dir,True)
            staged=set(os.listdir(files_dir))
            if not staged<=known_targets: fail("archive staging file set is invalid")
            for target in staged:
                value=os.lstat(os.path.join(files_dir,target))
                if (not stat.S_ISREG(value.st_mode) or value.st_uid!=uid or value.st_nlink!=1
                        or value.st_mode&0o022): fail("archive staging file is untrusted")
                os.unlink(os.path.join(files_dir,target))
            os.rmdir(files_dir)
        os.rmdir(directory)
    fsync_directory(releases)
def validate_record_shape(record,identifier):
    required={"approved_by_uid","archived_at","archived_at_unix_ns","assurance","commit",
              "files","product_version","release_id","schema","source_state_sha256","stamp"}
    if type(record) is not dict or set(record)!=required or record.get("schema")!=1:
        fail("release record schema is invalid")
    if record.get("release_id")!=identifier or record.get("approved_by_uid")!=uid:
        fail("release record identity is invalid")
    if (type(record.get("archived_at_unix_ns")) is not int or
            isinstance(record.get("archived_at_unix_ns"),bool) or record["archived_at_unix_ns"]<=0):
        fail("release archive time is invalid")
    if type(record.get("archived_at")) is not str or not record["archived_at"].endswith("Z"):
        fail("release archive timestamp is invalid")
    if record.get("assurance") not in {"pilot","enterprise"}:
        fail("release assurance is invalid")
    if type(record.get("files")) is not list:
        fail("release file inventory is invalid")
    targets=targets_for_names(
        [item.get("name") if type(item) is dict else None for item in record["files"]])
    for item in record["files"]:
        if set(item)!={"bytes","mode","name","sha256"} or type(item["bytes"]) is not int or item["bytes"]<0:
            fail("release file record is invalid")
        if (type(item["mode"]) is not int or type(item["sha256"]) is not str
                or not HEX.fullmatch(item["sha256"])):
            fail("release file record is malformed")
    if (type(record.get("commit")) is not str or not re.fullmatch(r"[0-9a-fA-F]{40,64}",record["commit"])
            or type(record.get("source_state_sha256")) is not str
            or not HEX.fullmatch(record["source_state_sha256"])
            or type(record.get("product_version")) is not str
            or type(record.get("stamp")) is not str):
        fail("release metadata is malformed")
    if release_digest(record["files"])!=identifier:
        fail("release record digest is invalid")
def validate_release(identifier,with_payload=False):
    if not HEX.fullmatch(identifier): fail("release id must be one full lowercase SHA-256 digest")
    if not open_registry(False): fail("release registry does not exist")
    directory=os.path.join(releases,"release-"+identifier); secure_directory(directory,True)
    if set(os.listdir(directory))!={"files","record.json"}: fail("release archive contains unknown entries")
    files_dir=os.path.join(directory,"files"); secure_directory(files_dir,True)
    record_raw,_=stable_read(os.path.join(directory,"record.json"),262144,expected_mode=0o600)
    try: record=json.loads(record_raw)
    except (UnicodeDecodeError,json.JSONDecodeError): fail("release record is not valid JSON")
    if canonical(record)!=record_raw: fail("release record is not canonical JSON")
    validate_record_shape(record,identifier)
    targets=targets_for_names([item["name"] for item in record["files"]])
    if set(os.listdir(files_dir))!=set(targets): fail("release archive file set is incomplete")
    total=0; payloads={}
    for item in record["files"]:
        name=item["name"]
        if name in RESOURCE_FILES:
            raw,mode=resource_read(os.path.join(files_dir,name))
            if mode!=item["mode"]: fail("archived resource mode differs from its record")
        else:
            raw,mode=stable_read(os.path.join(files_dir,name),MAX_FILE,
                                 expected_mode=item["mode"],
                                 executable=True if name in executables else False)
        total+=len(raw)
        if total>MAX_TOTAL or len(raw)!=item["bytes"] or hashlib.sha256(raw).hexdigest()!=item["sha256"]:
            fail("archived release bytes do not match their record")
        if with_payload: payloads[name]=raw
    manifest=parse_manifest(payloads["kist-current.manifest"] if with_payload else
                            stable_read(os.path.join(files_dir,"kist-current.manifest"),262144,
                                        expected_mode=0o600)[0])
    if (set(RESOURCE_KEYS.values())<=set(manifest)) != (targets==v4_targets):
        fail("archive resource inventory and manifest disagree")
    if targets==v4_targets:
        for item in record["files"]:
            if item["name"] in RESOURCE_KEYS and item["sha256"]!=manifest[RESOURCE_KEYS[item["name"]]]:
                fail("archive resource digest and manifest disagree")
    return record,record_raw,payloads
def create_file(path,raw,mode):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode)
    try: write_all(fd,raw); os.fchmod(fd,mode); os.fsync(fd)
    finally: os.close(fd)
def fsync_directory(path):
    fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)
def atomic_output(path,payload):
    if not os.path.isabs(path) or os.path.abspath(path)!=path or os.path.lexists(path):
        fail("plan output must be a new absolute path")
    parent=os.path.dirname(path); secure_directory(parent)
    create_file(path,payload,0o600); fsync_directory(parent)
def plan_body(plan):
    return {key:plan[key] for key in
             ["created_at","created_at_unix_ns","current_release_id","schema",
              "target_record_sha256","target_release_id","target_rollback_semantics"]}
def validate_plan(path,confirm=None):
    if not os.path.isabs(path) or os.path.abspath(path)!=path: fail("plan path must be absolute")
    raw,_=stable_read(path,65536,expected_mode=0o600)
    try: plan=json.loads(raw)
    except (UnicodeDecodeError,json.JSONDecodeError): fail("rollback plan is not valid JSON")
    required={"created_at","created_at_unix_ns","current_release_id","plan_digest","schema",
              "target_record_sha256","target_release_id","target_rollback_semantics"}
    if type(plan) is not dict or set(plan)!=required or plan.get("schema")!=1 or canonical(plan)!=raw:
        fail("rollback plan is not canonical")
    for key in ["current_release_id","plan_digest","target_record_sha256","target_release_id"]:
        if type(plan.get(key)) is not str or not HEX.fullmatch(plan[key]): fail("rollback plan digest is invalid")
    if plan["target_rollback_semantics"] not in {
            "exact-v4-with-resources","best-effort-v3-resources-not-archived",
            "best-effort-legacy-non-self-contained"}:
        fail("rollback plan semantics are invalid")
    if (type(plan.get("created_at")) is not str or not plan["created_at"].endswith("Z")
            or type(plan.get("created_at_unix_ns")) is not int
            or isinstance(plan["created_at_unix_ns"],bool) or plan["created_at_unix_ns"]<=0):
        fail("rollback plan timestamp is invalid")
    expected=hashlib.sha256(b"kist-rollback-plan-v1\0"+canonical(plan_body(plan))).hexdigest()
    if plan["plan_digest"]!=expected or (confirm is not None and confirm!=expected):
        fail("rollback plan confirmation does not match")
    if plan["current_release_id"]==plan["target_release_id"]: fail("rollback target equals current release")
    return plan

if action=="status":
    if arguments: fail("status takes no values")
    identifier,files,_,manifest=current_inventory()
    archived=False
    if open_registry(False) and "release-"+identifier in release_names():
        validate_release(identifier); archived=True
    print(canonical({"archived":archived,"assurance":manifest["deployment-assurance"],
                     "commit":manifest["commit"],"current_release_id":identifier,
                     "product_version":manifest["product-version"],
                     "rollback_semantics":rollback_semantics(
                         targets_for_names([item["name"] for item in files])),
                     "schema":1}).decode(),end="")
elif action=="list":
    if arguments: fail("list takes no values")
    values=[]
    for name in release_names():
        identifier=name[8:]; record,raw,_=validate_release(identifier)
        values.append({"archived_at":record["archived_at"],"assurance":record["assurance"],
                       "commit":record["commit"],"product_version":record["product_version"],
                       "record_sha256":hashlib.sha256(raw).hexdigest(),"release_id":identifier,
                       "rollback_semantics":rollback_semantics(
                           targets_for_names([item["name"] for item in record["files"]]))})
    print(canonical({"releases":values,"schema":1}).decode(),end="")
elif action=="archive":
    if len(arguments)!=1 or not HEX.fullmatch(arguments[0]):
        fail("archive requires one full lowercase current release digest")
    confirm=arguments[0]; identifier,files,payloads,manifest=current_inventory(True)
    if confirm!=identifier: fail("archive confirmation does not match the current deployment")
    if "safe-rebuild-sha256" not in manifest:
        fail("legacy transitional deployments may be validated but not archived; complete the v3 promotion")
    operational={"dashboard-runtime-sha256","dashboard-cortex-sha256","dashboard-cortex-count"}
    if not operational<=set(manifest):
        fail("unbound v3 compatibility deployments may be validated but not archived; promote the exact operational binding")
    if not set(RESOURCE_KEYS.values())<=set(manifest):
        fail("resource-unbound transitional deployments may be validated but not archived; complete the v4 promotion")
    open_registry(True); cleanup_archive_staging(); names=release_names()
    if "release-"+identifier in names:
        record,raw,_=validate_release(identifier)
        print(canonical({"created":False,"record_sha256":hashlib.sha256(raw).hexdigest(),
                         "release_id":identifier,"schema":1}).decode(),end="")
        raise SystemExit(0)
    if len(names)>=MAX_RELEASES: fail("release registry reached its 32-release bound")
    timestamp_ns=time.time_ns()
    timestamp=datetime.datetime.fromtimestamp(timestamp_ns/1_000_000_000,
                                               datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00","Z")
    record={"approved_by_uid":uid,"archived_at":timestamp,"archived_at_unix_ns":timestamp_ns,
            "assurance":manifest["deployment-assurance"],"commit":manifest["commit"],"files":files,
            "product_version":manifest["product-version"],"release_id":identifier,"schema":1,
            "source_state_sha256":manifest["source-state-sha256"],"stamp":manifest["stamp"]}
    record_raw=canonical(record); validate_record_shape(record,identifier)
    staging=os.path.join(releases,".release-staging."+secrets.token_hex(16))
    os.mkdir(staging,0o700); files_dir=os.path.join(staging,"files"); os.mkdir(files_dir,0o700)
    for item in files:
        create_file(os.path.join(files_dir,item["name"]),payloads[item["name"]],item["mode"])
    create_file(os.path.join(staging,"record.json"),record_raw,0o600)
    fsync_directory(files_dir); fsync_directory(staging)
    os.rename(staging,os.path.join(releases,"release-"+identifier)); fsync_directory(releases)
    validate_release(identifier)
    print(canonical({"created":True,"record_sha256":hashlib.sha256(record_raw).hexdigest(),
                     "release_id":identifier,"schema":1}).decode(),end="")
elif action=="plan":
    if len(arguments)!=2: fail("plan requires TARGET_RELEASE_ID and absolute output path")
    target,out=arguments; current,_,_,_=current_inventory()
    if current==target: fail("rollback target equals current release")
    target_record,record_raw,_=validate_release(target)
    timestamp_ns=time.time_ns()
    timestamp=datetime.datetime.fromtimestamp(timestamp_ns/1_000_000_000,
                                               datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00","Z")
    body={"created_at":timestamp,"created_at_unix_ns":timestamp_ns,"current_release_id":current,
          "schema":1,"target_record_sha256":hashlib.sha256(record_raw).hexdigest(),
          "target_release_id":target,
          "target_rollback_semantics":rollback_semantics(
              targets_for_names([item["name"] for item in target_record["files"]]))}
    plan=dict(body); plan["plan_digest"]=hashlib.sha256(b"kist-rollback-plan-v1\0"+canonical(body)).hexdigest()
    atomic_output(out,canonical(plan))
    print(canonical({"current_release_id":current,"plan":out,"plan_digest":plan["plan_digest"],
                     "schema":1,"target_release_id":target,
                     "target_rollback_semantics":plan["target_rollback_semantics"]}).decode(),end="")
elif action=="stage":
    if len(arguments)!=2: fail("stage requires PLAN and full plan digest")
    plan=validate_plan(arguments[0],arguments[1])
    current,_,_,_=current_inventory()
    if current!=plan["current_release_id"]: fail("current deployment changed after rollback planning")
    _,record_raw,payloads=validate_release(plan["target_release_id"],True)
    if hashlib.sha256(record_raw).hexdigest()!=plan["target_record_sha256"]:
        fail("target release record changed after rollback planning")
    record_files=json.loads(record_raw)["files"]
    targets=targets_for_names([item["name"] for item in record_files])
    if plan["target_rollback_semantics"]!=rollback_semantics(targets):
        fail("rollback plan semantics do not match the target archive")
    staged=[]
    try:
        for name in targets:
            path=os.path.join(bindir,".kist-rollback-stage."+secrets.token_hex(16))
            mode=next(item["mode"] for item in record_files if item["name"]==name)
            create_file(path,payloads[name],mode); staged.append(path)
        fsync_directory(bindir)
    except BaseException:
        for path in staged:
            try: os.unlink(path)
            except FileNotFoundError: pass
        raise
    print("target-release-id="+plan["target_release_id"])
    for name,path in zip(targets,staged): print(name+"="+path)
else:
    fail("unknown registry action")
PY
  registry_status=$?
  [ "$registry_status" -eq 0 ] || return "$registry_status"
  case "$registry_action" in
    status|list|plan) require_deployment_lease ;;
    *) require_deployment_lease exclusive ;;
  esac
}
