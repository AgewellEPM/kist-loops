"""Fixed SwiftPM resource contract, embedded into the authenticated launchers.

Run render_launchers.py after editing. Installed code never imports this checkout.
"""
import ctypes
import errno
import hashlib
import os
import stat
import sys

RESOURCE_ROOT = "AgentCore_AgentCore.bundle"
RESOURCE_FILES = {
    "kist-resource-code-investigation.md": "builtin/code-investigation/SKILL.md",
    "kist-resource-web-research.md": "builtin/web-research/SKILL.md",
}
RESOURCE_KEYS = {
    "kist-resource-code-investigation.md": "resource-code-investigation-sha256",
    "kist-resource-web-research.md": "resource-web-research-sha256",
}
RESOURCE_DIRS = [RESOURCE_ROOT, RESOURCE_ROOT + "/builtin"] + [
    RESOURCE_ROOT + "/builtin/" + name for name in ("code-investigation", "web-research")
]


def resource_fp(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_size,
            value.st_nlink, value.st_mtime_ns, value.st_ctime_ns)


def resource_acl(fd):
    library = ctypes.CDLL(None, use_errno=True)
    library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    library.acl_get_fd_np.restype = ctypes.c_void_p
    library.acl_free.argtypes = [ctypes.c_void_p]
    ctypes.set_errno(0)
    value = library.acl_get_fd_np(fd, 256)
    if value:
        library.acl_free(value)
        raise RuntimeError("resource ACL is not permitted")
    if ctypes.get_errno() not in {errno.ENOENT, errno.EINVAL, errno.ENOTSUP}:
        raise RuntimeError("resource ACL inspection failed")


def resource_read(path):
    before = os.lstat(path)
    if (os.path.realpath(path) != path or not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid() or before.st_nlink != 1
            or before.st_mode & 0o133 or before.st_size > 1024 * 1024):
        raise RuntimeError("resource file type, ownership, mode, size or ancestry is unsafe")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        resource_acl(fd)
        if resource_fp(os.fstat(fd)) != resource_fp(before):
            raise RuntimeError("resource changed before read")
        chunks = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(fd, remaining)
            if not chunk:
                raise RuntimeError("resource short read")
            chunks.append(chunk)
            remaining -= len(chunk)
        if (os.read(fd, 1) or resource_fp(os.fstat(fd)) != resource_fp(before)
                or resource_fp(os.lstat(path)) != resource_fp(before)):
            raise RuntimeError("resource changed during read")
        return b"".join(chunks), stat.S_IMODE(before.st_mode)
    finally:
        os.close(fd)


def resource_tree(root, complete=True, builtin_only=False):
    """Reject unknown entries and unsafe/moving directories; return all present bytes."""
    expected = {"": {"builtin"}, "builtin": {"code-investigation", "web-research"},
                "builtin/code-investigation": {"SKILL.md"},
                "builtin/web-research": {"SKILL.md"}}
    if builtin_only:
        expected = {path.removeprefix("builtin").lstrip("/"): names
                    for path, names in expected.items() if path}
    opened = []
    result = {}
    try:
        for relative, names in expected.items():
            path = os.path.join(root, relative) if relative else root
            try:
                before = os.lstat(path)
            except FileNotFoundError:
                if complete:
                    raise RuntimeError("resource directory is missing")
                continue
            if (os.path.realpath(path) != path or not stat.S_ISDIR(before.st_mode)
                    or before.st_uid != os.geteuid() or before.st_mode & 0o022):
                raise RuntimeError("resource directory is unsafe")
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            opened.append((path, fd, resource_fp(before)))
            resource_acl(fd)
            actual = set(os.listdir(fd))
            if (actual != names if complete else not actual <= names):
                raise RuntimeError("resource inventory is incomplete or contains unexpected entries")
        for alias, relative in RESOURCE_FILES.items():
            if builtin_only:
                relative = relative.removeprefix("builtin/")
            path = os.path.join(root, relative)
            try:
                result[alias] = resource_read(path)
            except FileNotFoundError:
                if complete:
                    raise RuntimeError("resource file is missing")
        for path, fd, identity in opened:
            if resource_fp(os.fstat(fd)) != identity or resource_fp(os.lstat(path)) != identity:
                raise RuntimeError("resource directory changed during inventory")
        return result
    finally:
        for _, fd, _ in reversed(opened):
            os.close(fd)


def resource_destination(bindir, alias):
    return os.path.join(bindir, RESOURCE_ROOT, RESOURCE_FILES[alias])
