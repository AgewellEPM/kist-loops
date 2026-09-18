"""Check required local release inputs before spending any model calls."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat

from process import save, sha

REQUIRED_SKILLS = ('builtin/code-investigation/SKILL.md', 'builtin/web-research/SKILL.md')


def capture_release(binary):
    binary = Path(binary).resolve(strict=True)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError('release binary is not an executable regular file')
    resources = binary.parent / 'AgentCore_AgentCore.bundle'
    files = {}
    for name in REQUIRED_SKILLS:
        descriptor = os.open(resources, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            parts = name.split('/')
            for part in parts[:-1]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                os.close(descriptor); descriptor = child
            leaf = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
            try:
                before = os.fstat(leaf)
                if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= 262144:
                    raise ValueError('required skill is not a bounded nonempty regular file: ' + name)
                data = b''
                while len(data) <= 262144:
                    block = os.read(leaf, min(65536, 262145 - len(data)))
                    if not block: break
                    data += block
                after = os.fstat(leaf)
                fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
                if len(data) != before.st_size or any(getattr(before, k) != getattr(after, k) for k in fields):
                    raise ValueError('required skill changed during inspection: ' + name)
                data.decode('utf-8')
                files[name] = hashlib.sha256(data).hexdigest()
            finally:
                os.close(leaf)
        finally:
            os.close(descriptor)
    return {'resolved_binary': str(binary), 'binary_sha256': sha(binary),
            'resource_root': str(resources), 'required_resources': files,
            'scope': 'executable and two required built-in skills; not a whole deployment attestation'}


def check_release(binary, output, expected=None):
    result = {'schema': 'kist.roadmap-release-preflight.v1', 'passed': False,
              'new_model_calls': 0, 'closure': None, 'issues': []}
    try:
        result['closure'] = capture_release(binary)
        if expected is not None and result['closure'] != expected:
            result['issues'].append('release binary or required resources changed')
        result['passed'] = not result['issues']
    except (OSError, ValueError) as error:
        result['issues'].append(type(error).__name__ + ': ' + str(error))
    save(output, result)
    return result
