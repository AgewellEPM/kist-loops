#!/bin/sh -p
# Build and lease-serialize a journaled promotion from one explicit or provenance-bound checkout.
# Multi-file visibility is not globally atomic for readers outside the lease; failures roll back.
# No sibling-directory scan is permitted: a stale or partial deployment must fail closed.
set -eu
umask 077
unset ENV BASH_ENV CDPATH

INSTALL_HOME=/Users/lukekist
GIT=/usr/bin/git
PYTHON=/usr/bin/python3
SHASUM=/usr/bin/shasum
SWIFT=/usr/bin/swift
SAFE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
PATH=$SAFE_PATH
HOME=$INSTALL_HOME
export PATH HOME
DASHBOARD_LAUNCHER="$INSTALL_HOME/bin/kist-dashboard"
DASHBOARD_REBUILD="$INSTALL_HOME/bin/kist-rebuild"
DASHBOARD_RUNTIME="$INSTALL_HOME/.kist/scripts/kist_runtime.py"
# Build snapshots and suite logs live below one owner-private per-installation directory.  Never
# enumerate a shared sticky directory for stale names: a different local UID must not be able to
# wedge recovery by reserving one of our fixed-format names.
DEFAULT_SNAPSHOT_PARENT="$INSTALL_HOME/.kist-rebuild-private-tmp"
SNAPSHOT_PARENT=${KIST_REBUILD_SNAPSHOT_PARENT:-$DEFAULT_SNAPSHOT_PARENT}
case "$SNAPSHOT_PARENT" in
  /*/.kist-rebuild-private-tmp) ;;
  *) echo "error: KIST_REBUILD_SNAPSHOT_PARENT must be an absolute owner-private .kist-rebuild-private-tmp directory" >&2; exit 1 ;;
esac
# The exact unsigned candidate used by enterprise evidence belongs to Kist, not SwiftPM's mutable
# convenience layout (`.build/release` is normally a symlink). Both publication and finalization
# traverse this fixed namespace with no-follow directory descriptors.
UNSIGNED_PROVENANCE_DIR=.kist-provenance

die() { echo "error: $*" >&2; exit 1; }
[ -x "$PYTHON" ] && [ ! -L "$PYTHON" ] || die "trusted system python is unavailable"
[ -x "$SWIFT" ] && [ ! -L "$SWIFT" ] || die "trusted system Swift is unavailable"

python_clean() {
  /usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" LANG=C LC_ALL=C \
    TMPDIR=/private/tmp PYTHONNOUSERSITE=1 "$PYTHON" -I "$@" 9>&-
}

# @KIST_RESOURCE_PROTOCOL@

swift_clean() {
  /usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" LANG=C LC_ALL=C \
    TMPDIR=/private/tmp "$SWIFT" "$@" 9>&-
}

is_kist_repo() {
  [ -f "$1/Package.swift" ] \
    && [ -f "$1/Sources/Kist/KistRunner.swift" ] \
    && [ -f "$1/Sources/AgentCore/CaptainOrchestrator.swift" ] \
    && [ -f "$1/Tests/KistTests/KistOptionsTests.swift" ] \
    && /usr/bin/grep -Fq '.executable(name: "kist"' "$1/Package.swift" 2>/dev/null
}

validated_repo() {
  case "$1" in /*) ;; *) return 1 ;; esac
  is_kist_repo "$1" || return 1
  (cd -P -- "$1" 2>/dev/null && pwd)
}

sha256_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  "$SHASUM" -a 256 "$1" | /usr/bin/awk '{print $1}'
}

stable_sha256_file() {
  python_clean - "$1" <<'PY'
import hashlib,os,stat,sys
path=sys.argv[1]; before=os.lstat(path)
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
identity=fp(before)
if (not stat.S_ISREG(before.st_mode) or before.st_uid!=os.geteuid()
        or before.st_nlink!=1 or before.st_mode&0o022 or before.st_size>262144):
    raise SystemExit(1)
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW); digest=hashlib.sha256()
try:
    if fp(os.fstat(fd))!=identity: raise SystemExit(1)
    remaining=before.st_size
    while remaining:
        block=os.read(fd,min(1024*1024,remaining))
        if not block: raise SystemExit(1)
        digest.update(block); remaining-=len(block)
    if os.read(fd,1) or fp(os.fstat(fd))!=identity or fp(os.lstat(path))!=identity:
        raise SystemExit(1)
finally:
    os.close(fd)
print(digest.hexdigest())
PY
}

stage_stable_executable() {
  python_clean - "$1" "$2" <<'PY'
import hashlib,os,stat,sys
source,target=sys.argv[1:]
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
before=os.lstat(source); identity=fp(before)
if (not stat.S_ISREG(before.st_mode) or before.st_uid!=os.geteuid()
        or before.st_nlink!=1 or before.st_mode&0o022 or before.st_size>512*1024*1024):
    raise SystemExit(1)
target_before=os.lstat(target)
if (not stat.S_ISREG(target_before.st_mode) or target_before.st_uid!=os.geteuid()
        or target_before.st_nlink!=1 or target_before.st_mode&0o022
        or target_before.st_size!=0):
    raise SystemExit(1)
src=os.open(source,os.O_RDONLY|os.O_NOFOLLOW)
dst=os.open(target,os.O_WRONLY|os.O_NOFOLLOW)
digest=hashlib.sha256(); total=0
try:
    if fp(os.fstat(src))!=identity or fp(os.fstat(dst))!=fp(target_before): raise SystemExit(1)
    while True:
        block=os.read(src,1024*1024)
        if not block: break
        offset=0
        while offset<len(block):
            written=os.write(dst,block[offset:])
            if written<=0: raise SystemExit(1)
            offset+=written
        digest.update(block); total+=len(block)
    if (total!=before.st_size or os.read(src,1) or fp(os.fstat(src))!=identity
            or fp(os.lstat(source))!=identity):
        raise SystemExit(1)
    os.fchmod(dst,0o755); os.fsync(dst)
finally:
    os.close(src); os.close(dst)
print(digest.hexdigest())
PY
}

publish_unsigned_artifact() {
  python_clean - "$1" "$2" "$UNSIGNED_PROVENANCE_DIR" <<'PY'
import hashlib,os,re,secrets,stat,sys
root,source,namespace=sys.argv[1:]; uid=os.geteuid()
if os.path.realpath(root)!=root: raise SystemExit(1)
if namespace!=".kist-provenance": raise SystemExit(1)
MAX_RETAINED=64; MAX_RETAINED_BYTES=8*1024*1024*1024
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
def dfp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid)
def open_directory_at(parent,name,create=False):
    try: named=os.stat(name,dir_fd=parent,follow_symlinks=False)
    except FileNotFoundError:
        if not create: raise
        os.mkdir(name,0o700,dir_fd=parent)
        named=os.stat(name,dir_fd=parent,follow_symlinks=False)
    if not stat.S_ISDIR(named.st_mode) or named.st_uid!=uid or named.st_mode&0o022:
        raise SystemExit(1)
    fd=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
    if dfp(os.fstat(fd))!=dfp(named): os.close(fd); raise SystemExit(1)
    return fd,dfp(named)
rst=os.lstat(root)
if not stat.S_ISDIR(rst.st_mode) or rst.st_uid!=uid or rst.st_mode&0o022:
    raise SystemExit(1)
rfd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
temp=".unsigned-kist."+secrets.token_hex(16); sfd=None; dfd=None; bfd=None; out=None
try:
    if dfp(os.fstat(rfd))!=dfp(rst): raise SystemExit(1)
    bfd,bid=open_directory_at(rfd,".build",True)
    dfd,did=open_directory_at(bfd,namespace,True)
    before=os.lstat(source); identity=fp(before)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid!=uid or before.st_nlink!=1
            or before.st_mode&0o022 or before.st_size>512*1024*1024):
        raise SystemExit(1)
    sfd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW)
    if fp(os.fstat(sfd))!=identity: raise SystemExit(1)
    out=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o700,dir_fd=dfd)
    digest=hashlib.sha256(); total=0
    while True:
        block=os.read(sfd,1024*1024)
        if not block: break
        offset=0
        while offset<len(block):
            written=os.write(out,block[offset:])
            if written<=0: raise SystemExit(1)
            offset+=written
        digest.update(block); total+=len(block)
    if total!=before.st_size or fp(os.fstat(sfd))!=identity or fp(os.lstat(source))!=identity:
        raise SystemExit(1)
    target=digest.hexdigest(); count=0; retained_bytes=0; removed=False; retained_meta=[]
    for name in os.listdir(dfd):
        if name==temp: continue
        if re.fullmatch(r"\.unsigned-kist\.[0-9a-f]{32}",name):
            stale=os.stat(name,dir_fd=dfd,follow_symlinks=False)
            if (not stat.S_ISREG(stale.st_mode) or stale.st_uid!=uid or stale.st_nlink!=1
                    or stale.st_mode&0o022):
                raise SystemExit(1)
            os.unlink(name,dir_fd=dfd); removed=True
        elif re.fullmatch(r"[0-9a-f]{64}",name):
            if name==target: continue
            retained=os.stat(name,dir_fd=dfd,follow_symlinks=False)
            if (not stat.S_ISREG(retained.st_mode) or retained.st_uid!=uid
                    or retained.st_nlink!=1 or retained.st_mode&0o022
                    or retained.st_size>512*1024*1024):
                raise SystemExit(1)
            count+=1; retained_bytes+=retained.st_size
            retained_meta.append((retained.st_mtime_ns,name,retained.st_size))
        else:
            raise SystemExit(1)
    # AUTO-EVICT oldest-first instead of wedging every deploy at the cap (2026-08-08: with no
    # eviction, once 64 SHA artifacts accumulated EVERY deploy died here). These are build-time
    # provenance evidence, not the deployed binary (rollback uses the v3 release archives), so
    # dropping the oldest to make room for the one being published is safe. Same fail-closed
    # security posture: re-stat under the dir fd with O_NOFOLLOW and re-check the exact identity
    # before unlink — never widen what we delete.
    retained_meta.sort()  # oldest mtime first
    idx=0
    while (count+1>MAX_RETAINED or retained_bytes+before.st_size>MAX_RETAINED_BYTES) and idx<len(retained_meta):
        _,victim,vsize=retained_meta[idx]; idx+=1
        if victim==target: continue
        vst=os.stat(victim,dir_fd=dfd,follow_symlinks=False)
        if (not stat.S_ISREG(vst.st_mode) or vst.st_uid!=uid or vst.st_nlink!=1
                or vst.st_mode&0o022 or vst.st_size!=vsize):
            raise SystemExit(1)
        os.unlink(victim,dir_fd=dfd); removed=True
        count-=1; retained_bytes-=vsize
    if removed: os.fsync(dfd)
    if count+1>MAX_RETAINED or retained_bytes+before.st_size>MAX_RETAINED_BYTES:
        raise SystemExit(1)
    os.fchmod(out,0o755); os.fsync(out)
    if (dfp(os.fstat(dfd))!=did
            or dfp(os.stat(namespace,dir_fd=bfd,follow_symlinks=False))!=did
            or dfp(os.fstat(bfd))!=bid
            or dfp(os.stat(".build",dir_fd=rfd,follow_symlinks=False))!=bid
            or dfp(os.fstat(rfd))!=dfp(rst)
            or dfp(os.lstat(root))!=dfp(rst)):
        raise SystemExit(1)
    os.replace(temp,target,src_dir_fd=dfd,dst_dir_fd=dfd)
    published=fp(os.fstat(out))
    if fp(os.stat(target,dir_fd=dfd,follow_symlinks=False))!=published:
        raise SystemExit(1)
    os.fsync(dfd)
    if (dfp(os.fstat(dfd))!=did
            or dfp(os.stat(namespace,dir_fd=bfd,follow_symlinks=False))!=did
            or dfp(os.fstat(bfd))!=bid
            or dfp(os.stat(".build",dir_fd=rfd,follow_symlinks=False))!=bid
            or dfp(os.fstat(rfd))!=dfp(rst)
            or dfp(os.lstat(root))!=dfp(rst)):
        raise SystemExit(1)
    print(digest.hexdigest())
finally:
    if out is not None: os.close(out)
    if sfd is not None: os.close(sfd)
    if dfd is not None:
        try: os.unlink(temp,dir_fd=dfd)
        except FileNotFoundError: pass
        os.close(dfd)
    if bfd is not None: os.close(bfd)
    os.close(rfd)
PY
}

retained_unsigned_artifact_sha256() {
  python_clean - "$1" "$2" "$UNSIGNED_PROVENANCE_DIR" <<'PY'
import hashlib,os,re,stat,sys
root,target,namespace=sys.argv[1:]; uid=os.geteuid()
if os.path.realpath(root)!=root: raise SystemExit(1)
if namespace!=".kist-provenance" or not re.fullmatch(r"[0-9a-f]{64}",target):
    raise SystemExit(1)
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
def dfp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid)
def open_directory_at(parent,name):
    named=os.stat(name,dir_fd=parent,follow_symlinks=False)
    if not stat.S_ISDIR(named.st_mode) or named.st_uid!=uid or named.st_mode&0o022:
        raise SystemExit(1)
    fd=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
    if dfp(os.fstat(fd))!=dfp(named): os.close(fd); raise SystemExit(1)
    return fd,dfp(named)
rst=os.lstat(root)
if not stat.S_ISDIR(rst.st_mode) or rst.st_uid!=uid or rst.st_mode&0o022:
    raise SystemExit(1)
rfd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
bfd=None; dfd=None; fd=None
try:
    if dfp(os.fstat(rfd))!=dfp(rst): raise SystemExit(1)
    bfd,bid=open_directory_at(rfd,".build")
    dfd,did=open_directory_at(bfd,namespace)
    before=os.stat(target,dir_fd=dfd,follow_symlinks=False); identity=fp(before)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid!=uid or before.st_nlink!=1
            or before.st_mode&0o022 or not before.st_mode&stat.S_IXUSR
            or before.st_size>512*1024*1024):
        raise SystemExit(1)
    fd=os.open(target,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=dfd)
    if fp(os.fstat(fd))!=identity: raise SystemExit(1)
    digest=hashlib.sha256(); remaining=before.st_size
    while remaining:
        block=os.read(fd,min(1024*1024,remaining))
        if not block: raise SystemExit(1)
        digest.update(block); remaining-=len(block)
    if (os.read(fd,1) or fp(os.fstat(fd))!=identity
            or fp(os.stat(target,dir_fd=dfd,follow_symlinks=False))!=identity
            or dfp(os.fstat(dfd))!=did
            or dfp(os.stat(namespace,dir_fd=bfd,follow_symlinks=False))!=did
            or dfp(os.fstat(bfd))!=bid
            or dfp(os.stat(".build",dir_fd=rfd,follow_symlinks=False))!=bid
            or dfp(os.fstat(rfd))!=dfp(rst)
            or dfp(os.lstat(root))!=dfp(rst)):
        raise SystemExit(1)
    value=digest.hexdigest()
    if value!=target: raise SystemExit(1)
    print(value)
finally:
    if fd is not None: os.close(fd)
    if dfd is not None: os.close(dfd)
    if bfd is not None: os.close(bfd)
    os.close(rfd)
PY
}

source_inventory() {
  python_clean - "$1" "${2-}" <<'PY'
import hashlib,os,stat,sys
root=os.path.realpath(sys.argv[1]); destination_arg=sys.argv[2]
destination=os.path.realpath(destination_arg) if destination_arg else None
MAX_FILE=512*1024*1024; MAX_TOTAL=2*1024*1024*1024; MAX_PATHS=32*1024*1024
def fp(s): return (s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_nlink,s.st_mtime_ns,s.st_ctime_ns)
# Every logical child directory is an input too: Package.swift and build tools are executable code
# and may branch on empty-directory existence or permission mode.  The snapshot root itself is a
# deliberately normalized 0700 privacy boundary, so records begin with its children.
entries=[]; visited=total=paths=0
destination_fd=None
if destination is not None:
    if destination!=destination_arg or destination==root or destination.startswith(root+"/"):
        raise SystemExit(1)
    dst=os.lstat(destination)
    if (not stat.S_ISDIR(dst.st_mode) or dst.st_uid!=os.geteuid()
            or stat.S_IMODE(dst.st_mode)!=0o700 or os.listdir(destination)):
        raise SystemExit(1)
    destination_fd=os.open(destination,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    if fp(os.fstat(destination_fd))!=fp(dst): raise SystemExit(1)
def write_all(fd,data):
    offset=0
    while offset<len(data):
        written=os.write(fd,data[offset:])
        if written<=0: raise RuntimeError("short write")
        offset+=written
def read_file(parent,name,identity,size,target_parent=None):
    fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=parent)
    out=None
    try:
        if fp(os.fstat(fd))!=identity: raise RuntimeError("race")
        if target_parent is not None:
            out=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,
                        dir_fd=target_parent)
        digest=hashlib.sha256(); remaining=size
        while remaining:
            b=os.read(fd,min(1024*1024,remaining))
            if not b: raise RuntimeError("short")
            digest.update(b)
            if out is not None: write_all(out,b)
            remaining-=len(b)
        if os.read(fd,1) or fp(os.fstat(fd))!=identity or fp(os.stat(name,dir_fd=parent,follow_symlinks=False))!=identity: raise RuntimeError("race")
        if out is not None:
            os.fchmod(out,stat.S_IMODE(identity[2])); os.fsync(out)
        return digest.digest()
    finally:
        os.close(fd)
        if out is not None: os.close(out)
def walk(fd,prefix,target_fd=None):
    global visited,total,paths
    initial=fp(os.fstat(fd)); observed=[]
    with os.scandir(os.dup(fd)) as scan: names=sorted((e.name for e in scan),key=lambda x:x.encode())
    for name in names:
        rel=f"{prefix}/{name}" if prefix else name; visited+=1
        if visited>250000 or len(rel.encode())>16384: raise RuntimeError("inventory bound")
        st=os.stat(name,dir_fd=fd,follow_symlinks=False); identity=fp(st); observed.append((name,identity))
        # SwiftPM/Xcode build-product directories at any depth and the two high-churn telemetry
        # paths are not source. `.build-local` is the repo's ignored alternate SwiftPM cache and
        # may contain generated symlinks. The rest of root .kist (notably agents/, plan.json, and
        # checked-in learning policy) is a runtime/build input and must be copied and hashed.
        if not prefix and name==".git":
            if stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode): continue
            raise RuntimeError("git metadata has an invalid type")
        if rel==".kist/usage.jsonl":
            if stat.S_ISREG(st.st_mode): continue
            raise RuntimeError("usage telemetry has an invalid type")
        if rel==".kist/runs":
            if stat.S_ISDIR(st.st_mode): continue
            raise RuntimeError("run telemetry has an invalid type")
        if name in {".build",".build-local","DerivedData"}:
            # Build output at ANY depth is a regenerable artifact, never source — skip it (and never
            # descend, so a nested SwiftPM `.build/debug` symlink can't choke the source hasher). Was
            # `not prefix and …` (root-only), which let e.g. mcp-server/.build/debug fail the snapshot.
            if stat.S_ISDIR(st.st_mode): continue
            raise RuntimeError("build output has an invalid type")
        if stat.S_ISDIR(st.st_mode):
            rb=rel.encode(); paths+=len(rb)
            if paths>MAX_PATHS: raise RuntimeError("aggregate bound")
            entries.append((rb,b"D",stat.S_IMODE(st.st_mode),b""))
            child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            target_child=None
            try:
                if fp(os.fstat(child))!=identity: raise RuntimeError("directory race")
                if target_fd is not None:
                    os.mkdir(name,0o700,dir_fd=target_fd)
                    target_child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,
                                         dir_fd=target_fd)
                walk(child,rel,target_child)
                if target_child is not None:
                    os.fchmod(target_child,stat.S_IMODE(st.st_mode)); os.fsync(target_child)
                if fp(os.fstat(child))!=identity or fp(os.stat(name,dir_fd=fd,follow_symlinks=False))!=identity: raise RuntimeError("directory changed")
            finally:
                os.close(child)
                if target_child is not None: os.close(target_child)
        elif stat.S_ISREG(st.st_mode):
            rb=rel.encode(); total+=st.st_size; paths+=len(rb)
            if st.st_size>MAX_FILE or total>MAX_TOTAL or paths>MAX_PATHS: raise RuntimeError("aggregate bound")
            entries.append((rb,b"F",stat.S_IMODE(st.st_mode),
                            read_file(fd,name,identity,st.st_size,target_fd)))
        else: raise RuntimeError(f"source symlink/special: {rel}")
    if fp(os.fstat(fd))!=initial: raise RuntimeError("directory changed")
    for name,identity in observed:
        if fp(os.stat(name,dir_fd=fd,follow_symlinks=False))!=identity: raise RuntimeError("name changed")
parent=os.path.dirname(root); leaf=os.path.basename(root)
if not leaf: raise SystemExit(1)
pfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW); parent_id=fp(os.fstat(pfd))
try:
    root_named=fp(os.stat(leaf,dir_fd=pfd,follow_symlinks=False))
    fd=os.open(leaf,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=pfd)
    try:
        if fp(os.fstat(fd))!=root_named: raise RuntimeError("root race")
        walk(fd,"",destination_fd)
        if fp(os.fstat(fd))!=root_named or fp(os.stat(leaf,dir_fd=pfd,follow_symlinks=False))!=root_named or fp(os.fstat(pfd))!=parent_id: raise RuntimeError("root changed")
    finally: os.close(fd)
finally: os.close(pfd)
entries.sort(key=lambda x:(x[0],x[1])); digest=hashlib.sha256(b"kist-source-state-v2\0")
for path,kind,mode,payload in entries:
    digest.update(len(path).to_bytes(8,"big"));digest.update(path);digest.update(kind);digest.update(mode.to_bytes(4,"big"));digest.update(len(payload).to_bytes(8,"big"));digest.update(payload)
if destination_fd is not None:
    os.fsync(destination_fd); os.close(destination_fd)
print(digest.hexdigest())
PY
}
source_state() {
  source_inventory "$1"
}
snapshot_source() {
  source_inventory "$1" "$2"
}
remove_source_snapshot() {
  [ -n "${1-}" ] || return 0
  python_clean - "$1" "$SNAPSHOT_PARENT" <<'PY'
import ctypes,errno,os,re,stat,sys
path,parent=sys.argv[1:]; uid=os.geteuid()
leaf=os.path.basename(path)
if (os.path.dirname(path)!=parent or os.path.realpath(parent)!=parent
        or not re.fullmatch(r"kist-source-snapshot\.[A-Za-z0-9]{6}",leaf)):
    raise SystemExit(1)
try: value=os.lstat(path)
except FileNotFoundError: raise SystemExit(0)
def identity(item): return (item.st_dev,item.st_ino,item.st_mode,item.st_uid)
if (not stat.S_ISDIR(value.st_mode) or value.st_uid!=uid
        or stat.S_IMODE(value.st_mode)!=0o700 or os.path.realpath(path)!=path):
    raise SystemExit(1)
pfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
libc=ctypes.CDLL(None,use_errno=True)
libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]
libc.acl_get_fd_np.restype=ctypes.c_void_p
libc.acl_free.argtypes=[ctypes.c_void_p]
def has_acl(fd):
    ctypes.set_errno(0); acl=libc.acl_get_fd_np(fd,256)
    if acl:
        libc.acl_free(acl); return True
    if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
    raise SystemExit(1)
def same_directory(left,right):
    return (stat.S_ISDIR(left.st_mode) and stat.S_ISDIR(right.st_mode)
            and (left.st_dev,left.st_ino,left.st_uid)==(right.st_dev,right.st_ino,right.st_uid))
def remove_tree(parent_fd,name,root_dev,root=False):
    named=os.stat(name,dir_fd=parent_fd,follow_symlinks=False); named_id=identity(named)
    if (not stat.S_ISDIR(named.st_mode) or named.st_uid!=uid or named.st_dev!=root_dev
            or (root and stat.S_IMODE(named.st_mode)!=0o700)):
        raise SystemExit(1)
    directory=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent_fd)
    try:
        opened=os.fstat(directory)
        rebound=os.stat(name,dir_fd=parent_fd,follow_symlinks=False)
        if identity(opened)!=named_id or identity(rebound)!=named_id or (root and has_acl(directory)):
            raise SystemExit(1)
        # Snapshot children deliberately preserve source directory modes, including read-only
        # 0555/0550 directories.  Rebind the opened descriptor to its still-identical name before
        # changing only this owner-private snapshot inode; otherwise unlink/rmdir can fail after a
        # successful deployment.  All later checks use the new descriptor/name identity.
        os.fchmod(directory,0o700)
        writable=os.fstat(directory)
        rebound=os.stat(name,dir_fd=parent_fd,follow_symlinks=False)
        writable_id=identity(writable)
        if (not same_directory(writable,named) or identity(rebound)!=writable_id
                or stat.S_IMODE(writable.st_mode)!=0o700):
            raise SystemExit(1)
        with os.scandir(os.dup(directory)) as scan:
            names=sorted((entry.name for entry in scan),key=lambda item:item.encode())
        for child_name in names:
            child=os.stat(child_name,dir_fd=directory,follow_symlinks=False)
            if child.st_uid!=uid or child.st_dev!=root_dev: raise SystemExit(1)
            if stat.S_ISDIR(child.st_mode):
                remove_tree(directory,child_name,root_dev)
            elif (stat.S_ISREG(child.st_mode) or stat.S_ISLNK(child.st_mode)
                  or stat.S_ISFIFO(child.st_mode) or stat.S_ISSOCK(child.st_mode)):
                if not stat.S_ISLNK(child.st_mode) and child.st_nlink!=1: raise SystemExit(1)
                os.unlink(child_name,dir_fd=directory)
            else:
                raise SystemExit(1)
        if (identity(os.fstat(directory))!=writable_id
                or identity(os.stat(name,dir_fd=parent_fd,follow_symlinks=False))!=writable_id):
            raise SystemExit(1)
    finally: os.close(directory)
    os.rmdir(name,dir_fd=parent_fd)
try:
    remove_tree(pfd,leaf,value.st_dev,True)
    os.fsync(pfd)
finally: os.close(pfd)
PY
}

