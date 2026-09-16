# Re-inventory immediately before returning validation or starting Python so ordinary same-account
# startup drift fails closed. The installation UID is the trust boundary: that principal also owns
# this process and can rewrite or debug it after this check, so this is not a claim of lifetime
# cortex immutability. Runtime execution is stronger and remains pinned to an exact open descriptor.
revalidate_operational_state() {
  local output actual_closure actual_runtime actual_cortex actual_count
  assert_lease deployment
  if [[ "$CLOSURE_VERSION" == 3 || "$CLOSURE_VERSION" == 4 ]]; then
    set -- "$INSTALL_HOME/bin/kist-current" "$INSTALL_HOME/bin/kist" \
      "$DASHBOARD_LAUNCHER" "$DASHBOARD_REBUILD" "$INSTALL_HOME/bin/kist-safe-rebuild.sh"
    if [[ "$CLOSURE_VERSION" == 4 ]]; then
      set -- "$@" \
        "$INSTALL_HOME/bin/AgentCore_AgentCore.bundle/builtin/code-investigation/SKILL.md" \
        "$INSTALL_HOME/bin/AgentCore_AgentCore.bundle/builtin/web-research/SKILL.md"
    fi
    output=$("$DASHBOARD_LAUNCHER" --provenance-evaluate "$@" 9>&-) || return 1
    actual_runtime=$(projection_value "$output" dashboard-runtime-sha256) || return 1
    actual_cortex=$(projection_value "$output" dashboard-cortex-sha256) || return 1
    actual_count=$(projection_value "$output" dashboard-cortex-count) || return 1
    [[ "$actual_runtime" == "$RUNTIME_SHA" && "$actual_cortex" == "$CORTEX_SHA" \
       && "$actual_count" == "$CORTEX_COUNT" ]] || return 1
  else
    output=$("$DASHBOARD_LAUNCHER" --provenance-evaluate \
      "$INSTALL_HOME/bin/kist-current" "$INSTALL_HOME/bin/kist" \
      "$DASHBOARD_LAUNCHER" "$DASHBOARD_REBUILD" 9>&-) || return 1
  fi
  actual_closure=$(projection_value "$output" artifact-closure-sha256) || return 1
  [[ "$actual_closure" == "$CLOSURE_SHA" ]] || return 1
  assert_lease deployment
}
if [[ "${KIST_REBUILD_TESTING-}" == 1 \
      && -n "${KIST_DASHBOARD_TEST_AFTER_PROVENANCE_VALIDATION_HOOK-}" ]]; then
  [[ "$INSTALL_HOME" != /Users/lukekist ]] \
    || die 'dashboard provenance hooks are forbidden for production'
  PROVENANCE_HOOK="$KIST_DASHBOARD_TEST_AFTER_PROVENANCE_VALIDATION_HOOK"
  [[ "$PROVENANCE_HOOK" = /* && -x "$PROVENANCE_HOOK" && ! -L "$PROVENANCE_HOOK" ]] \
    || die 'dashboard provenance hook is not one absolute executable file'
  /usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" LANG=C LC_ALL=C \
    "$PROVENANCE_HOOK" 9>&- || die 'dashboard provenance hook failed'
fi
if [[ "$VALIDATE" -eq 1 ]]; then
  revalidate_operational_state \
    || die 'dashboard artifacts or operational state changed after provenance validation'
  exit 0
fi

TOKEN="${KIST_DASHBOARD_TOKEN-}"
BOOTSTRAP="${KIST_DASHBOARD_BOOTSTRAP-}"
BROWSER_HOST="${KIST_DASHBOARD_BROWSER_HOST-}"
if [[ -n "$TOKEN" || -n "$BOOTSTRAP" || -n "$BROWSER_HOST" ]]; then
  [[ -n "$TOKEN" && -n "$BOOTSTRAP" && -n "$BROWSER_HOST" ]] || die 'incomplete credential set'
else
  read -r TOKEN BOOTSTRAP BROWSER_HOST < <(python_clean - <<'PY'
import secrets
print(secrets.token_urlsafe(48),secrets.token_urlsafe(48),f"kist-{secrets.token_hex(16)}.localhost")
PY
  )
fi
[[ "$TOKEN" =~ ^[A-Za-z0-9_-]{32,128}$ && "$BOOTSTRAP" =~ ^[A-Za-z0-9_-]{32,128}$ && "$BROWSER_HOST" =~ ^kist-[a-f0-9]{32}\.localhost$ ]] || die 'invalid credential set'

ARGS=(dashboard --serve --port "$PORT" --project-root "$PROJECT_ROOT")
[[ -z "$VIEW" ]] || ARGS+=(--view "$VIEW")
[[ "$CONTROL" -eq 0 ]] || ARGS+=(--allow-control)
[[ "$NO_OPEN" -eq 0 ]] || ARGS+=(--no-open)
RUN_DIR="$KIST_HOME/run"
OWNER="$RUN_DIR/dashboard-$PORT.owner"
assert_lease deployment
python_clean - "$KIST_HOME" <<'PY' || die 'dashboard run directory is untrusted'
import ctypes,errno,os,stat,sys
home=sys.argv[1]; uid=os.geteuid()
def fp(value): return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
libc=ctypes.CDLL(None,use_errno=True); libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]; libc.acl_get_fd_np.restype=ctypes.c_void_p; libc.acl_free.argtypes=[ctypes.c_void_p]
def acl(fd):
    ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
    if value: libc.acl_free(value); return True
    if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
    raise SystemExit(1)
if os.path.realpath(home)!=home: raise SystemExit(1)
hst=os.lstat(home)
if not stat.S_ISDIR(hst.st_mode) or hst.st_uid!=uid or hst.st_mode&0o022: raise SystemExit(1)
hfd=os.open(home,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
    if fp(os.fstat(hfd))!=fp(hst) or acl(hfd): raise SystemExit(1)
    try: os.mkdir("run",0o700,dir_fd=hfd)
    except FileExistsError: pass
    refreshed=os.fstat(hfd)
    if (refreshed.st_dev,refreshed.st_ino,refreshed.st_mode,refreshed.st_uid)!=(hst.st_dev,hst.st_ino,hst.st_mode,hst.st_uid): raise SystemExit(1)
    hid=fp(refreshed)
    if fp(os.lstat(home))!=hid: raise SystemExit(1)
    rst=os.stat("run",dir_fd=hfd,follow_symlinks=False)
    if not stat.S_ISDIR(rst.st_mode) or rst.st_uid!=uid or stat.S_IMODE(rst.st_mode)!=0o700: raise SystemExit(1)
    rfd=os.open("run",os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=hfd)
    try:
        if fp(os.fstat(rfd))!=fp(rst) or acl(rfd): raise SystemExit(1)
        if fp(os.stat("run",dir_fd=hfd,follow_symlinks=False))!=fp(rst) or fp(os.fstat(hfd))!=hid or fp(os.lstat(home))!=hid: raise SystemExit(1)
        os.fsync(hfd)
    finally: os.close(rfd)
finally: os.close(hfd)
PY
SERVER_PID=""
BOOT_RECEIPT=""
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup_dashboard() {
  if [[ -n "$SERVER_PID" ]] && /bin/kill -0 "$SERVER_PID" 2>/dev/null; then
    /bin/kill -TERM "$SERVER_PID" 2>/dev/null || true
  fi
  [[ -z "$BOOT_RECEIPT" ]] || /bin/rm -f "$BOOT_RECEIPT"
  release_all_leases
}
trap cleanup_dashboard EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
start_lease launch exclusive "$RUN_DIR/dashboard-$PORT.launch.lock"
assert_lease deployment
assert_lease launch

BOOT_RECEIPT="$RUN_DIR/.dashboard-$PORT.runtime-${TOKEN:0:32}.receipt"
BOOTSTRAP_CODE=$(/bin/cat <<'PY'
import ctypes,errno,hashlib,os,secrets,stat,sys
runtime,expected,receipt,bootstrap_sha,*runtime_args=sys.argv[1:]
uid=os.geteuid()
def fp(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
libc=ctypes.CDLL(None,use_errno=True)
libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]
libc.acl_get_fd_np.restype=ctypes.c_void_p
libc.acl_free.argtypes=[ctypes.c_void_p]
def acl(fd):
    ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
    if value: libc.acl_free(value); return True
    if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
    raise SystemExit(126)
if (not os.path.isabs(runtime) or os.path.realpath(runtime)!=runtime or len(expected)!=64
        or any(c not in "0123456789abcdef" for c in expected)): raise SystemExit(126)
named=os.lstat(runtime)
if (not stat.S_ISREG(named.st_mode) or named.st_uid!=uid or named.st_nlink!=1 or named.st_mode&0o022
        or named.st_size>512*1024*1024): raise SystemExit(126)
fd=os.open(runtime,os.O_RDONLY|os.O_NOFOLLOW)
if fp(os.fstat(fd))!=fp(named) or acl(fd): raise SystemExit(126)
chunks=[]; digest=hashlib.sha256(); remaining=named.st_size
while remaining:
    block=os.read(fd,min(1024*1024,remaining))
    if not block: raise SystemExit(126)
    digest.update(block); chunks.append(block); remaining-=len(block)
if os.read(fd,1) or fp(os.fstat(fd))!=fp(named) or digest.hexdigest()!=expected: raise SystemExit(126)
source=b"".join(chunks)
code=compile(source,runtime,"exec",dont_inherit=True)
run=os.path.dirname(receipt); leaf=os.path.basename(receipt)
rst=os.lstat(run)
if (not leaf or "/" in leaf or not stat.S_ISDIR(rst.st_mode) or rst.st_uid!=uid
        or stat.S_IMODE(rst.st_mode)!=0o700): raise SystemExit(126)
rfd=os.open(run,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
temp=f".{leaf}.{secrets.token_hex(16)}"
try:
    if fp(os.fstat(rfd))!=fp(rst): raise SystemExit(126)
    out=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=rfd)
    try:
        payload=(f"pid={os.getpid()}\nruntime-sha256={expected}\nruntime-device={named.st_dev}\n"
                 f"runtime-inode={named.st_ino}\nruntime-mode={stat.S_IMODE(named.st_mode)}\n"
                 f"runtime-size={named.st_size}\nruntime-fd={fd}\nbootstrap-sha256={bootstrap_sha}\n").encode()
        offset=0
        while offset<len(payload):
            written=os.write(out,payload[offset:])
            if written<=0: raise SystemExit(126)
            offset+=written
        os.fsync(out)
    finally: os.close(out)
    os.replace(temp,leaf,src_dir_fd=rfd,dst_dir_fd=rfd); os.fsync(rfd)
finally:
    try: os.unlink(temp,dir_fd=rfd)
    except FileNotFoundError: pass
    os.close(rfd)
# Keep the validated descriptor reachable for the process lifetime and execute the exact bytes read
# from it while retaining the canonical path expected by runtime-relative imports and diagnostics.
sys.argv=[runtime,*runtime_args]
sys.path.insert(0,os.path.dirname(runtime))
namespace={"__name__":"__main__","__file__":runtime,"__package__":None,"__cached__":None,
           "__spec__":None,"_kist_validated_runtime_fd":fd}
exec(code,namespace,namespace)
PY
)
read -r BOOTSTRAP_SHA ARGV_SHA PYTHON_EXEC_SHA < <(python_clean - "$BOOTSTRAP_CODE" "$RUNTIME" "$RUNTIME_SHA" "$BOOT_RECEIPT" "${ARGS[@]}" <<'PY'
import ctypes,hashlib,os,sys
code,*tail=sys.argv[1:]
def proc_executable(pid):
    libc=ctypes.CDLL(None,use_errno=True); mib=(ctypes.c_int*3)(1,49,pid); size=ctypes.c_size_t()
    if libc.sysctl(mib,3,None,ctypes.byref(size),None,0): raise SystemExit(1)
    data=ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib,3,data,ctypes.byref(size),None,0): raise SystemExit(1)
    raw=data.raw[:size.value]; end=raw.find(b"\0",4)
    if end<0: raise SystemExit(1)
    return raw[4:end].decode("utf-8")
bootstrap=hashlib.sha256(code.encode()).hexdigest()
arguments=["-I","-c",code,*tail[:3],bootstrap,*tail[3:]]
argv_sha=hashlib.sha256(b"\0".join(value.encode() for value in arguments)).hexdigest()
executable_sha=hashlib.sha256(proc_executable(os.getpid()).encode()).hexdigest()
print(bootstrap,argv_sha,executable_sha)
PY
)
[[ "$BOOTSTRAP_SHA" =~ ^[a-f0-9]{64}$ && "$ARGV_SHA" =~ ^[a-f0-9]{64}$ \
   && "$PYTHON_EXEC_SHA" =~ ^[a-f0-9]{64}$ ]] || die 'cannot bind the exact dashboard bootstrap identity'

LISTENERS=()
while IFS= read -r listener; do
  [[ -z "$listener" ]] || LISTENERS+=("$listener")
done < <(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | /usr/bin/sort -u || true)
if (( ${#LISTENERS[@]} > 1 )); then die "multiple listeners already own :$PORT"; fi
assert_lease deployment
assert_lease launch
if (( ${#LISTENERS[@]} == 1 )); then
  OLD_PID="${LISTENERS[0]}"
  [[ "$OLD_PID" =~ ^[0-9]+$ ]] || die "invalid listener identity on :$PORT"
  python_clean - "$RUN_DIR" "dashboard-$PORT.owner" "$OLD_PID" "$PORT" "$RUNTIME" <<'PY' \
    || die "refusing to replace unowned, unauthenticated, or mismatched listener on :$PORT"
import ctypes,errno,hashlib,json,os,signal,stat,subprocess,sys,urllib.request
run,name,pid_text,port,runtime=sys.argv[1:]; pid=int(pid_text); uid=os.geteuid()
def fp(value): return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
libc=ctypes.CDLL(None,use_errno=True); libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]; libc.acl_get_fd_np.restype=ctypes.c_void_p; libc.acl_free.argtypes=[ctypes.c_void_p]
def acl(fd):
    ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
    if value: libc.acl_free(value); return True
    if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
    raise SystemExit(1)
def procargs(target):
    mib=(ctypes.c_int*3)(1,49,target); size=ctypes.c_size_t()
    if libc.sysctl(mib,3,None,ctypes.byref(size),None,0): raise SystemExit(1)
    data=ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib,3,data,ctypes.byref(size),None,0): raise SystemExit(1)
    raw=data.raw[:size.value]; argc=int.from_bytes(raw[:4],sys.byteorder,signed=True); pos=4; end=raw.find(b"\0",pos)
    if argc<1 or argc>64 or end<0: raise SystemExit(1)
    executable=raw[pos:end].decode("utf-8"); pos=end
    while pos<len(raw) and raw[pos]==0: pos+=1
    argv=[]
    while pos<len(raw) and len(argv)<argc:
        end=raw.find(b"\0",pos)
        if end<0: raise SystemExit(1)
        argv.append(raw[pos:end].decode("utf-8")); pos=end+1
    if len(argv)!=argc: raise SystemExit(1)
    return executable,argv
rst=os.lstat(run)
if not stat.S_ISDIR(rst.st_mode) or rst.st_uid!=uid or stat.S_IMODE(rst.st_mode)!=0o700: raise SystemExit(1)
rfd=os.open(run,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
    if fp(os.fstat(rfd))!=fp(rst) or acl(rfd): raise SystemExit(1)
    st=os.stat(name,dir_fd=rfd,follow_symlinks=False); ident=fp(st)
    if not stat.S_ISREG(st.st_mode) or st.st_uid!=uid or st.st_mode&0o077 or st.st_size>4096: raise SystemExit(1)
    fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=rfd)
    try:
        if fp(os.fstat(fd))!=ident or acl(fd): raise SystemExit(1)
        chunks=[]; total=0
        while True:
            block=os.read(fd,min(4097-total,4096))
            if not block: break
            total+=len(block)
            if total>4096: raise SystemExit(1)
            chunks.append(block)
        if fp(os.fstat(fd))!=ident or fp(os.stat(name,dir_fd=rfd,follow_symlinks=False))!=ident or fp(os.fstat(rfd))!=fp(rst): raise SystemExit(1)
    finally: os.close(fd)
finally: os.close(rfd)
raw=b"".join(chunks)
if not raw.endswith(b"\n") or b"\r" in raw: raise SystemExit(1)
values={}
for line in raw.decode("utf-8").splitlines():
    k,sep,v=line.partition("=")
    if not sep or not k or not v or k in values: raise SystemExit(1)
    values[k]=v
required={"pid","start","token","service","protocol","argv-sha256","python-executable-sha256",
          "runtime-sha256","runtime-device","runtime-inode","runtime-mode","runtime-size","runtime-fd",
          "bootstrap-sha256"}
if set(values)!=required or values["pid"]!=pid_text or values["service"]!="kist-live-dashboard" or values["protocol"]!="1": raise SystemExit(1)
for key in ["argv-sha256","python-executable-sha256","runtime-sha256","bootstrap-sha256"]:
    if len(values[key])!=64 or any(c not in "0123456789abcdef" for c in values[key]): raise SystemExit(1)
for key in ["runtime-device","runtime-inode","runtime-mode","runtime-size","runtime-fd"]:
    if not values[key].isdigit() or str(int(values[key]))!=values[key]: raise SystemExit(1)
req=urllib.request.Request(f"http://127.0.0.1:{port}/api/meta",headers={"Authorization":"Bearer "+values["token"]})
with urllib.request.urlopen(req,timeout=.8) as response: meta=json.load(response)
if (type(meta) is not dict or type(meta.get("service")) is not str or meta["service"]!="kist-live-dashboard"
        or type(meta.get("protocol")) is not int or meta["protocol"]!=1
        or type(meta.get("authenticated")) is not bool or meta["authenticated"] is not True): raise SystemExit(1)
current=subprocess.run(["/bin/ps","-o","lstart=","-p",pid_text],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=1,check=True).stdout.decode().strip()
if current!=values["start"]: raise SystemExit(1)
executable,argv=procargs(pid)
if not argv or argv[0]!=executable or len(argv)<14 or argv[1:3]!=["-I","-c"]: raise SystemExit(1)
if hashlib.sha256(argv[3].encode()).hexdigest()!=values["bootstrap-sha256"]: raise SystemExit(1)
if argv[4]!=runtime or argv[5]!=values["runtime-sha256"] or argv[7]!=values["bootstrap-sha256"]: raise SystemExit(1)
if os.path.dirname(argv[6])!=run or not os.path.basename(argv[6]).startswith(f".dashboard-{port}.runtime-"): raise SystemExit(1)
if argv[8:13] != ["dashboard","--serve","--port",port,"--project-root"]: raise SystemExit(1)
if not os.path.isabs(argv[13]) or os.path.realpath(argv[13])!=argv[13] or not os.path.isdir(argv[13]): raise SystemExit(1)
tail=argv[14:]; index=0; seen=set()
while index<len(tail):
    option=tail[index]
    if option=="--view" and option not in seen and index+1<len(tail) and tail[index+1] in {"conversation","flow","timeline","fleet","plan"}: index+=2
    elif option in {"--allow-control","--no-open"} and option not in seen: index+=1
    else: raise SystemExit(1)
    seen.add(option)
actual_argv=hashlib.sha256(b"\0".join(value.encode("utf-8") for value in argv[1:])).hexdigest()
actual_executable=hashlib.sha256(executable.encode("utf-8")).hexdigest()
if actual_argv!=values["argv-sha256"] or actual_executable!=values["python-executable-sha256"]: raise SystemExit(1)
fd=values["runtime-fd"]
lsof=subprocess.run(["/usr/sbin/lsof","-a","-p",pid_text,"-d",fd,"-F","fDin"],stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=1,check=True).stdout.decode().splitlines()
parsed={line[:1]:line[1:] for line in lsof if line[:1] in {"f","D","i","n"}}
if parsed.get("f")!=fd or int(parsed.get("D","-1"),0)!=int(values["runtime-device"]) or int(parsed.get("i","-1"))!=int(values["runtime-inode"]): raise SystemExit(1)
os.kill(pid,signal.SIGTERM)
PY
  for _ in {1..20}; do /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1 || break; /bin/sleep .1; done
  /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1 && die "owned listener on :$PORT did not stop"
elif [[ -e "$OWNER" || -L "$OWNER" ]]; then
  python_clean - "$RUN_DIR" "dashboard-$PORT.owner" <<'PY' || die 'unsafe stale dashboard owner record'
import ctypes,errno,os,stat,sys
run,name=sys.argv[1:]; uid=os.geteuid()
def fp(value): return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
libc=ctypes.CDLL(None,use_errno=True); libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]; libc.acl_get_fd_np.restype=ctypes.c_void_p; libc.acl_free.argtypes=[ctypes.c_void_p]
def acl(fd):
    ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
    if value: libc.acl_free(value); return True
    if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
    raise SystemExit(1)
rst=os.lstat(run)
if not stat.S_ISDIR(rst.st_mode) or rst.st_uid!=uid or stat.S_IMODE(rst.st_mode)!=0o700: raise SystemExit(1)
rfd=os.open(run,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
    if fp(os.fstat(rfd))!=fp(rst) or acl(rfd): raise SystemExit(1)
    st=os.stat(name,dir_fd=rfd,follow_symlinks=False); ident=fp(st)
    if not stat.S_ISREG(st.st_mode) or st.st_uid!=uid or st.st_mode&0o077: raise SystemExit(1)
    fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=rfd)
    try:
        if fp(os.fstat(fd))!=ident or acl(fd): raise SystemExit(1)
        if fp(os.stat(name,dir_fd=rfd,follow_symlinks=False))!=ident: raise SystemExit(1)
    finally: os.close(fd)
    os.unlink(name,dir_fd=rfd); os.fsync(rfd)
finally: os.close(rfd)
PY
fi

assert_lease deployment
assert_lease launch
revalidate_operational_state \
  || die 'dashboard artifacts or operational state changed before Python startup'
assert_lease launch
/usr/bin/env -i HOME="$INSTALL_HOME" PATH="$SAFE_PATH" KIST_HOME="$KIST_HOME" \
  LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8" TMPDIR="/tmp" PYTHONNOUSERSITE=1 \
  PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 KIST_DASHBOARD_TOKEN="$TOKEN" \
  KIST_DASHBOARD_BOOTSTRAP="$BOOTSTRAP" KIST_DASHBOARD_BROWSER_HOST="$BROWSER_HOST" \
  "$PYTHON" -I -c "$BOOTSTRAP_CODE" "$RUNTIME" "$RUNTIME_SHA" "$BOOT_RECEIPT" \
  "$BOOTSTRAP_SHA" "${ARGS[@]}" 6>&- 7>&- 8>&- 9>&- &
SERVER_PID=$!
START="$(/bin/ps -o lstart= -p "$SERVER_PID" | /usr/bin/sed 's/^ *//;s/ *$//')"
[[ -n "$START" ]] || die 'dashboard child exited before its process receipt was captured'
for _ in {1..100}; do
  [[ -s "$BOOT_RECEIPT" ]] && break
  /bin/kill -0 "$SERVER_PID" 2>/dev/null || break
  /bin/sleep .05
done
[[ -s "$BOOT_RECEIPT" ]] || die 'dashboard child did not publish its pinned-runtime receipt'
python_clean - "$RUN_DIR" "dashboard-$PORT.owner" "${BOOT_RECEIPT##*/}" "$SERVER_PID" "$START" \
  "$TOKEN" "$SERVICE" "$ARGV_SHA" "$PYTHON_EXEC_SHA" "$RUNTIME_SHA" "$BOOTSTRAP_SHA" <<'PY'
import ctypes,errno,os,secrets,stat,sys
run,name,receipt_name,pid,start,token,service,argv_sha,python_sha,runtime_sha,bootstrap_sha=sys.argv[1:]; uid=os.geteuid()
def fp(value): return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_nlink,value.st_mtime_ns,value.st_ctime_ns)
libc=ctypes.CDLL(None,use_errno=True); libc.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int]; libc.acl_get_fd_np.restype=ctypes.c_void_p; libc.acl_free.argtypes=[ctypes.c_void_p]
def acl(fd):
    ctypes.set_errno(0); value=libc.acl_get_fd_np(fd,256)
    if value: libc.acl_free(value); return True
    if ctypes.get_errno() in {errno.ENOENT,errno.EINVAL,errno.ENOTSUP}: return False
    raise SystemExit(1)
rst=os.lstat(run)
if not stat.S_ISDIR(rst.st_mode) or rst.st_uid!=uid or stat.S_IMODE(rst.st_mode)!=0o700: raise SystemExit(1)
rfd=os.open(run,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
temp=f".{name}.{secrets.token_hex(16)}"
try:
    if fp(os.fstat(rfd))!=fp(rst) or acl(rfd): raise SystemExit(1)
    receipt_st=os.stat(receipt_name,dir_fd=rfd,follow_symlinks=False); receipt_id=fp(receipt_st)
    if not stat.S_ISREG(receipt_st.st_mode) or receipt_st.st_uid!=uid or stat.S_IMODE(receipt_st.st_mode)!=0o600 or receipt_st.st_size>4096: raise SystemExit(1)
    receipt_fd=os.open(receipt_name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=rfd)
    try:
        if fp(os.fstat(receipt_fd))!=receipt_id or acl(receipt_fd): raise SystemExit(1)
        receipt=os.read(receipt_fd,4097)
        if len(receipt)>4096 or fp(os.fstat(receipt_fd))!=receipt_id or fp(os.stat(receipt_name,dir_fd=rfd,follow_symlinks=False))!=receipt_id: raise SystemExit(1)
    finally: os.close(receipt_fd)
    if not receipt.endswith(b"\n") or b"\r" in receipt: raise SystemExit(1)
    runtime_values={}
    for line in receipt.decode("utf-8").splitlines():
        key,separator,value=line.partition("=")
        if not separator or not key or not value or key in runtime_values: raise SystemExit(1)
        runtime_values[key]=value
    runtime_required={"pid","runtime-sha256","runtime-device","runtime-inode","runtime-mode","runtime-size","runtime-fd","bootstrap-sha256"}
    if set(runtime_values)!=runtime_required or runtime_values["pid"]!=pid or runtime_values["runtime-sha256"]!=runtime_sha or runtime_values["bootstrap-sha256"]!=bootstrap_sha: raise SystemExit(1)
    for key in ["runtime-device","runtime-inode","runtime-mode","runtime-size","runtime-fd"]:
        value=runtime_values[key]
        if not value.isdigit() or str(int(value))!=value: raise SystemExit(1)
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=rfd)
    try:
        payload=(f"pid={pid}\nstart={start}\ntoken={token}\nservice={service}\nprotocol=1\n"
                 f"argv-sha256={argv_sha}\npython-executable-sha256={python_sha}\n"
                 f"runtime-sha256={runtime_values['runtime-sha256']}\n"
                 f"runtime-device={runtime_values['runtime-device']}\n"
                 f"runtime-inode={runtime_values['runtime-inode']}\n"
                 f"runtime-mode={runtime_values['runtime-mode']}\n"
                 f"runtime-size={runtime_values['runtime-size']}\n"
                 f"runtime-fd={runtime_values['runtime-fd']}\n"
                 f"bootstrap-sha256={runtime_values['bootstrap-sha256']}\n").encode("utf-8")
        offset=0
        while offset<len(payload):
            written=os.write(fd,payload[offset:])
            if written<=0: raise SystemExit(1)
            offset+=written
        os.fchmod(fd,0o600); os.fsync(fd)
    finally: os.close(fd)
    os.replace(temp,name,src_dir_fd=rfd,dst_dir_fd=rfd)
    os.fsync(rfd)
    st=os.stat(name,dir_fd=rfd,follow_symlinks=False)
    if not stat.S_ISREG(st.st_mode) or st.st_uid!=uid or stat.S_IMODE(st.st_mode)!=0o600: raise SystemExit(1)
    if fp(os.stat(receipt_name,dir_fd=rfd,follow_symlinks=False))!=receipt_id: raise SystemExit(1)
    os.unlink(receipt_name,dir_fd=rfd); os.fsync(rfd)
finally:
    try: os.unlink(temp,dir_fd=rfd)
    except FileNotFoundError: pass
    os.close(rfd)
PY
python_clean - "$SERVER_PID" "$PORT" "$TOKEN" <<'PY' || die 'dashboard child failed authenticated readiness'
import json,os,sys,time,urllib.request
pid=int(sys.argv[1]); port=sys.argv[2]; token=sys.argv[3]; deadline=time.monotonic()+5
while time.monotonic()<deadline:
    try: os.kill(pid,0)
    except ProcessLookupError: raise SystemExit(1)
    try:
        request=urllib.request.Request(f"http://127.0.0.1:{port}/api/meta",headers={"Authorization":"Bearer "+token})
        with urllib.request.urlopen(request,timeout=.25) as response: meta=json.load(response)
        if (type(meta) is dict and type(meta.get("service")) is str and meta["service"]=="kist-live-dashboard"
                and type(meta.get("protocol")) is int and meta["protocol"]==1
                and type(meta.get("authenticated")) is bool and meta["authenticated"] is True): raise SystemExit(0)
    except Exception: pass
    time.sleep(.05)
raise SystemExit(1)
PY
READY_PID=$(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | /usr/bin/sort -u)
[[ "$READY_PID" = "$SERVER_PID" ]] || die 'authenticated dashboard readiness did not match the recorded listener PID'
assert_lease launch
assert_lease deployment
release_lease launch
release_lease deployment
if wait "$SERVER_PID"; then status=0; else status=$?; fi
SERVER_PID=""
exit "$status"
