TRANSACTION_ACTIVE=0
transaction_control() {
  transaction_action=$1
  shift
  case "$transaction_action" in
    check-clean) require_deployment_lease ;;
    recover|begin|begin-finalize|rollback|commit) require_deployment_lease exclusive ;;
    *) die "unknown deployment transaction action" ;;
  esac
  resource_python "$INSTALL_HOME" "$SNAPSHOT_PARENT" "$transaction_action" "$@" <<'PY'
import ctypes,errno,hashlib,json,os,re,secrets,stat,sys
home,snapshot_parent,action,*stages=sys.argv[1:]
uid=os.geteuid(); home=os.path.realpath(home); bindir=os.path.join(home,"bin")
journal=os.path.join(bindir,".kist-rebuild-journal")
legacy_targets=["kist-current","kist","kist-dashboard","kist-rebuild","kist-current.manifest",".kist-build"]
legacy_full_targets=legacy_targets+["kist-current.provenance.json"]
full_targets=["kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh",
              "kist-current.manifest",".kist-build","kist-current.provenance.json"]
resource_targets=full_targets+list(RESOURCE_FILES)
finalize_targets=["kist-current.manifest","kist-current.provenance.json"]
executable_targets={"kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh"}
def fp(value): return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
bst=os.lstat(bindir)
if not stat.S_ISDIR(bst.st_mode) or bst.st_uid!=uid or bst.st_mode&0o022 or os.path.realpath(bindir)!=bindir: raise SystemExit(1)
bfd=os.open(bindir,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
if fp(os.fstat(bfd))!=fp(bst): raise SystemExit(1)
def fsync_dir(): os.fsync(bfd)
def target_path(name):
    return resource_destination(bindir,name) if name in RESOURCE_FILES else os.path.join(bindir,name)
def sync_parent(path):
    fd=os.open(os.path.dirname(path),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)
def remove_created_directories(value):
    if value.get("created_directories"):
        resource_tree(os.path.join(bindir,RESOURCE_ROOT),complete=False)
    for relative in reversed(value.get("created_directories",[])):
        path=os.path.join(bindir,relative)
        try: os.rmdir(path); sync_parent(path)
        except FileNotFoundError: pass
def secure_regular(path, executable=None):
    value=os.lstat(path)
    if not stat.S_ISREG(value.st_mode) or value.st_uid!=uid or value.st_nlink!=1 or value.st_mode&0o022: raise SystemExit(1)
    if executable is True and not value.st_mode&stat.S_IXUSR: raise SystemExit(1)
    if executable is False and stat.S_IMODE(value.st_mode)!=0o600: raise SystemExit(1)
    return value
def write_all(fd,data):
    offset=0
    while offset<len(data):
        written=os.write(fd,data[offset:])
        if written<=0: raise SystemExit(1)
        offset+=written
def atomic_json(payload):
    raw=(json.dumps(payload,sort_keys=True,separators=(",",":"))+"\n").encode()
    temp=f".kist-rebuild-journal.{secrets.token_hex(16)}"
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=bfd)
    try: write_all(fd,raw); os.fsync(fd)
    finally: os.close(fd)
    os.replace(temp,os.path.basename(journal),src_dir_fd=bfd,dst_dir_fd=bfd); fsync_dir()
def read_journal():
    st=secure_regular(journal,False)
    if st.st_size>65536: raise SystemExit(1)
    fd=os.open(os.path.basename(journal),os.O_RDONLY|os.O_NOFOLLOW,dir_fd=bfd)
    try:
        if fp(os.fstat(fd))!=fp(st): raise SystemExit(1)
        chunks=[]; remaining=st.st_size
        while remaining:
            block=os.read(fd,min(65536,remaining))
            if not block: raise SystemExit(1)
            chunks.append(block); remaining-=len(block)
        if os.read(fd,1) or fp(os.fstat(fd))!=fp(st): raise SystemExit(1)
    finally: os.close(fd)
    raw=b"".join(chunks)
    if not raw.endswith(b"\n") or b"\n" in raw[:-1] or b"\r" in raw: raise SystemExit(1)
    value=json.loads(raw)
    required={"schema","token","phase","backup","targets","present","installed"}
    if type(value) is not dict or type(value.get("schema")) is not int: raise SystemExit(1)
    if value["schema"]==2:
        required.add("created_directories")
        created=value.get("created_directories")
        if (type(created) is not list or any(type(name) is not str for name in created)
                or created!=[name for name in RESOURCE_DIRS if name in created]
                or value.get("targets")!=resource_targets): raise SystemExit(1)
    elif value["schema"]!=1: raise SystemExit(1)
    if set(value)!=required: raise SystemExit(1)
    if type(value["token"]) is not str or len(value["token"])!=32 or any(c not in "0123456789abcdef" for c in value["token"]): raise SystemExit(1)
    if type(value["phase"]) is not str or value["phase"] not in {"preparing","prepared","activating","active","rolling-back","rolled-back","committed"}: raise SystemExit(1)
    targets=value["targets"]
    if (targets!=legacy_targets and targets!=legacy_full_targets
            and targets!=full_targets and targets!=finalize_targets
            and targets!=resource_targets): raise SystemExit(1)
    if targets==resource_targets and value["schema"]!=2: raise SystemExit(1)
    if type(value["present"]) is not dict or set(value["present"])!=set(targets): raise SystemExit(1)
    if any(type(value["present"][name]) is not bool for name in targets): raise SystemExit(1)
    if type(value["installed"]) is not list or any(type(name) is not str for name in value["installed"]): raise SystemExit(1)
    if len(set(value["installed"]))!=len(value["installed"]) or any(name not in targets for name in value["installed"]): raise SystemExit(1)
    expected=f".kist-rebuild-backup.{value['token']}"
    if value["backup"]!=expected: raise SystemExit(1)
    return value
def copy_stable(source,destination,mode=None):
    before=secure_regular(source)
    src=os.open(source,os.O_RDONLY|os.O_NOFOLLOW)
    temp=destination+f".new.{secrets.token_hex(12)}"
    for alias in RESOURCE_FILES:
        if destination==target_path(alias):
            temp=os.path.join(bindir,alias+f".new.{secrets.token_hex(12)}")
    dst=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,stat.S_IMODE(before.st_mode))
    digest=hashlib.sha256(); total=0
    promoted=False
    try:
        try:
            while True:
                block=os.read(src,1024*1024)
                if not block: break
                write_all(dst,block); digest.update(block); total+=len(block)
            if total!=before.st_size or fp(os.fstat(src))!=fp(before): raise SystemExit(1)
            os.fchmod(dst,stat.S_IMODE(before.st_mode) if mode is None else mode); os.fsync(dst)
        finally:
            os.close(src); os.close(dst)
        os.replace(temp,destination); promoted=True; sync_parent(destination)
    finally:
        if not promoted:
            try: os.unlink(temp)
            except FileNotFoundError: pass
    return digest.hexdigest()
def remove_backup(value):
    backup=os.path.join(bindir,value["backup"])
    try:
        backup_st=os.lstat(backup)
        if (not stat.S_ISDIR(backup_st.st_mode) or backup_st.st_uid!=uid
                or stat.S_IMODE(backup_st.st_mode)!=0o700
                or os.path.realpath(backup)!=backup):
            raise SystemExit(1)
        names=os.listdir(backup)
    except FileNotFoundError: names=[]
    generated=re.compile(
        r"(?:"+"|".join(re.escape(name) for name in value["targets"])+r")\.new\.[0-9a-f]{24}")
    if any(name not in value["targets"] and not generated.fullmatch(name) for name in names):
        raise SystemExit(1)
    for name in names:
        path=os.path.join(backup,name); secure_regular(path); os.unlink(path)
    try: os.rmdir(backup)
    except FileNotFoundError: pass
def rollback(value):
    if value["targets"]==resource_targets:
        resource_tree(os.path.join(bindir,RESOURCE_ROOT),complete=False)
    for name in os.listdir(bindir):
        if any(re.fullmatch(re.escape(target)+r"\.new\.[0-9a-f]{24}",name)
               for target in value["targets"]):
            secure_regular(os.path.join(bindir,name)); os.unlink(name,dir_fd=bfd)
    value["phase"]="rolling-back"; atomic_json(value)
    backup=os.path.join(bindir,value["backup"])
    for name in value["targets"]:
        target=target_path(name); saved=os.path.join(backup,name)
        if value["present"][name]:
            secure_regular(saved)
            copy_stable(saved,target)
        else:
            try:
                current=os.lstat(target)
                if not stat.S_ISREG(current.st_mode) or current.st_uid!=uid: raise SystemExit(1)
                os.unlink(target); sync_parent(target)
            except FileNotFoundError: pass
    remove_created_directories(value)
    fsync_dir()
    value["phase"]="rolled-back"; atomic_json(value)
    remove_backup(value); os.unlink(journal); fsync_dir()
def finish_without_restore(value):
    if value["phase"]=="preparing": remove_created_directories(value)
    remove_backup(value)
    os.unlink(journal)
    fsync_dir()
def recover_journal(value):
    if value["phase"] in {"preparing","rolled-back","committed"}:
        finish_without_restore(value)
    else:
        rollback(value)
def cleanup_orphans():
    removed=False
    generated_target=re.compile(
        r"(?:"+"|".join(re.escape(name) for name in resource_targets)+r")\.new\.[0-9a-f]{24}")
    reserved_prefixes=[
        ".kist-current.new",".kist.wrapper",".kist-dashboard",".kist-rebuild",
        ".kist-safe-rebuild",".kist-current.manifest",".kist-build",
        ".kist-resource-code",".kist-resource-web",
        ".kist-current.provenance",".kist-status",".kist-notary-archive",
        ".kist-notary-result",".kist-current.manifest.final",
        ".kist-current.provenance.final",".kist-current.projection.final",
    ]
    reserved_temp=re.compile(
        r"(?:"+"|".join(re.escape(name) for name in reserved_prefixes)+r")\.[A-Za-z0-9]{6}")
    for name in os.listdir(bindir):
        path=os.path.join(bindir,name)
        if re.fullmatch(r"\.kist-rebuild-journal\.[0-9a-f]{32}",name):
            secure_regular(path); os.unlink(name,dir_fd=bfd); removed=True
        elif re.fullmatch(r"\.kist-rebuild-backup\.[0-9a-f]{32}",name):
            remove_backup({"backup":name,"targets":resource_targets}); removed=True
        elif generated_target.fullmatch(name):
            secure_regular(path); os.unlink(name,dir_fd=bfd); removed=True
        elif reserved_temp.fullmatch(name):
            secure_regular(path); os.unlink(name,dir_fd=bfd); removed=True
    if removed: fsync_dir()
def cleanup_stale_snapshots():
    # An explicit scratch volume is allowed for space-constrained installations,
    # but it must retain the fixed private-directory leaf and all of the existing
    # canonical-path, owner, mode, ACL, and bounded-name cleanup gates below.
    if (not os.path.isabs(snapshot_parent)
            or os.path.basename(snapshot_parent)!=".kist-rebuild-private-tmp"
            or os.path.realpath(snapshot_parent)!=snapshot_parent):
        raise SystemExit(1)
    try: parent_st=os.lstat(snapshot_parent)
    except FileNotFoundError:
        os.mkdir(snapshot_parent,0o700)
        os.chmod(snapshot_parent,0o700)
        parent_st=os.lstat(snapshot_parent)
    if (not stat.S_ISDIR(parent_st.st_mode) or parent_st.st_uid!=uid
            or stat.S_IMODE(parent_st.st_mode)!=0o700):
        raise SystemExit(1)
    parent_fd=os.open(snapshot_parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    libc=ctypes.CDLL(None,use_errno=True)
    libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]
    libc.acl_get_fd_np.restype=ctypes.c_void_p
    libc.acl_free.argtypes=[ctypes.c_void_p]
    def has_acl(fd):
        ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
        if value:
            libc.acl_free(value); return True
        if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
        raise SystemExit(1)
    def directory_identity(value):
        return (value.st_dev,value.st_ino,value.st_mode,value.st_uid)
    def same_directory(left,right):
        return (stat.S_ISDIR(left.st_mode) and stat.S_ISDIR(right.st_mode)
                and (left.st_dev,left.st_ino,left.st_uid)==(right.st_dev,right.st_ino,right.st_uid))
    def remove_tree(parent,name,root=False,root_dev=None):
        named=os.stat(name,dir_fd=parent,follow_symlinks=False); identity=directory_identity(named)
        if not stat.S_ISDIR(named.st_mode) or named.st_uid!=uid:
            raise SystemExit(1)
        if root and stat.S_IMODE(named.st_mode)!=0o700:
            raise SystemExit(1)
        if root_dev is None: root_dev=named.st_dev
        if named.st_dev!=root_dev: raise SystemExit(1)
        directory=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
        try:
            opened=os.fstat(directory)
            rebound=os.stat(name,dir_fd=parent,follow_symlinks=False)
            if (directory_identity(opened)!=identity or directory_identity(rebound)!=identity
                    or (root and has_acl(directory))):
                raise SystemExit(1)
            # A killed build can leave source-mode 0555/0550 descendants.  After proving the opened
            # inode is still bound to this private snapshot name, make only that inode owner-writable
            # and carry its new descriptor/name identity through recursive removal.
            os.fchmod(directory,0o700)
            writable=os.fstat(directory)
            rebound=os.stat(name,dir_fd=parent,follow_symlinks=False)
            writable_identity=directory_identity(writable)
            if (not same_directory(writable,named)
                    or directory_identity(rebound)!=writable_identity
                    or stat.S_IMODE(writable.st_mode)!=0o700):
                raise SystemExit(1)
            with os.scandir(os.dup(directory)) as scan:
                names=sorted((entry.name for entry in scan),key=lambda value:value.encode())
            for child_name in names:
                child=os.stat(child_name,dir_fd=directory,follow_symlinks=False)
                if child.st_uid!=uid or child.st_dev!=root_dev:
                    raise SystemExit(1)
                if stat.S_ISDIR(child.st_mode):
                    remove_tree(directory,child_name,root_dev=root_dev)
                elif (stat.S_ISREG(child.st_mode) or stat.S_ISLNK(child.st_mode)
                      or stat.S_ISFIFO(child.st_mode) or stat.S_ISSOCK(child.st_mode)):
                    if not stat.S_ISLNK(child.st_mode) and child.st_nlink!=1:
                        raise SystemExit(1)
                    os.unlink(child_name,dir_fd=directory)
                else:
                    raise SystemExit(1)
            if directory_identity(os.fstat(directory))!=writable_identity:
                raise SystemExit(1)
            if directory_identity(os.stat(name,dir_fd=parent,follow_symlinks=False))!=writable_identity:
                raise SystemExit(1)
        finally:
            os.close(directory)
        os.rmdir(name,dir_fd=parent)
    try:
        if fp(os.fstat(parent_fd))!=fp(parent_st) or has_acl(parent_fd):
            raise SystemExit(1)
        snapshot_name=re.compile(r"kist-source-snapshot\.[A-Za-z0-9]{6}")
        suite_name=re.compile(r"kist-rebuild-suite\.[A-Za-z0-9]{6}")
        changed=False
        for name in os.listdir(snapshot_parent):
            if snapshot_name.fullmatch(name):
                path=os.path.join(snapshot_parent,name)
                if os.path.realpath(path)!=path: raise SystemExit(1)
                remove_tree(parent_fd,name,root=True); changed=True
            elif suite_name.fullmatch(name):
                value=os.stat(name,dir_fd=parent_fd,follow_symlinks=False)
                if (not stat.S_ISREG(value.st_mode) or value.st_uid!=uid or value.st_nlink!=1
                        or value.st_mode&0o022):
                    raise SystemExit(1)
                os.unlink(name,dir_fd=parent_fd); changed=True
        if changed: os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
try:
    if action=="check-clean":
        if os.path.lexists(journal): raise SystemExit(1)
    elif action=="recover":
        if os.path.lexists(journal):
            value=read_journal()
            recover_journal(value)
        cleanup_orphans()
        cleanup_stale_snapshots()
        # A kill between archive validation and transaction begin can leave only these fixed-format,
        # owner-private stage files. The exclusive lease proves no live rollback can still own them.
        removed=False
        for name in os.listdir(bindir):
            if re.fullmatch(r"\.kist-rollback-stage\.[0-9a-f]{32}",name):
                secure_regular(os.path.join(bindir,name)); os.unlink(name,dir_fd=bfd); removed=True
        if removed: fsync_dir()
    elif action in {"begin","begin-finalize"}:
        if action=="begin":
            if len(stages)==len(resource_targets): targets=resource_targets
            elif len(stages)==len(full_targets): targets=full_targets
            elif len(stages)==len(legacy_full_targets): targets=legacy_full_targets
            else: raise SystemExit(1)
        else:
            targets=finalize_targets
        if len(stages)!=len(targets) or os.path.lexists(journal): raise SystemExit(1)
        for index,path in enumerate(stages):
            if not os.path.isabs(path) or os.path.dirname(path)!=bindir: raise SystemExit(1)
            if targets[index] in RESOURCE_FILES: resource_read(path)
            else: secure_regular(path,(targets[index] in executable_targets) if action=="begin" else False)
        created=[]
        if targets==resource_targets:
            resource_tree(os.path.join(bindir,RESOURCE_ROOT),complete=False)
            created=[name for name in RESOURCE_DIRS if not os.path.lexists(os.path.join(bindir,name))]
        token=secrets.token_hex(16); backup_name=f".kist-rebuild-backup.{token}"; backup=os.path.join(bindir,backup_name)
        os.mkdir(backup,0o700); present={}
        for name in targets:
            path=target_path(name)
            try:
                secure_regular(path); present[name]=True
            except FileNotFoundError: present[name]=False
        value={"schema":1,"token":token,"phase":"preparing","backup":backup_name,
               "targets":targets,"present":present,"installed":[]}
        if targets==resource_targets:
            value.update(schema=2,created_directories=created)
        atomic_json(value)
        for name in targets:
            if present[name]: copy_stable(target_path(name),os.path.join(backup,name))
        bkupfd=os.open(backup,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW); os.fsync(bkupfd); os.close(bkupfd)
        for relative in created:
            path=os.path.join(bindir,relative)
            os.mkdir(path,0o755); os.chmod(path,0o755); sync_parent(path)
        value["phase"]="prepared"; atomic_json(value)
        for name,stage in zip(targets,stages):
            os.replace(stage,target_path(name)); sync_parent(target_path(name))
            value["installed"].append(name)
            value["phase"]="activating"; atomic_json(value)
        fsync_dir(); value["phase"]="active"; atomic_json(value)
        print(token)
    elif action=="rollback":
        if os.path.lexists(journal): recover_journal(read_journal())
    elif action=="commit":
        value=read_journal()
        if value["phase"]!="active": raise SystemExit(1)
        value["phase"]="committed"; atomic_json(value)
        remove_backup(value); os.unlink(journal); fsync_dir()
    else: raise SystemExit(1)
finally: os.close(bfd)
PY
  transaction_status=$?
  [ "$transaction_status" -eq 0 ] || return "$transaction_status"
  # Commit itself is the terminal durable boundary.  Every other action remains reversible and is
  # followed by an exact helper-liveness check before its caller can continue.
  [ "$transaction_action" = commit ] || {
    case "$transaction_action" in
      check-clean) require_deployment_lease ;;
      *) require_deployment_lease exclusive ;;
    esac
  }
}
