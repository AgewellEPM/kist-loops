#!/usr/bin/env python3
"""Receipt-producing capability/failure-zone campaign for Kist and its legacy limbs.

The runner is intentionally boring: a versioned manifest, literal argv arrays (never a
shell), process-group deadlines, byte-hashed logs, explicit safety grants, and one JSON
receipt per step. Live desktop/VM control is never enabled implicitly.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any
import uuid


SCHEMA = "kist.codex-capability-campaign.v1"
PROVIDER_POLICY_SCHEMA = "kist.inference-provider-policy.v1"
RUN_STATE_SCHEMA = "kist.codex-capability-campaign.run.v3"
STEP_RECEIPT_SCHEMA = "kist.codex-capability-campaign.step.v3"
RESUME_POLICIES = {"reuse_only", "retry", "rerun"}
SAFETY_GRANTS = {
    "read_only": None,
    "workspace_build": "allow_workspace_builds",
    "subscription": "allow_subscription",
    "live_control": "allow_live_control",
}
ALLOWED_KINDS = {
    "command", "mcp_inventory", "mcp_safe_calls", "mcp_unarmed_denial", "cobol_heal",
    "codex_repair_cobol", "kist_grow_tool",
}
TOKEN = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
CONTEXT_KEY = re.compile(r"^[A-Z][A-Z0-9_]*$")
RESERVED_CONTEXT_KEYS = {"HOME", "TMP", "KIST_REPO", "RUNNER_SHA256"}
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SAFE_TOOL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SAFE_DIRECTORY_NAME = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
CORRELATION_ID = re.compile(r"^[0-9a-f]{64}$")
REVIEW_GRADES = {"fresh_context_same_model"}


class CampaignInterrupted(BaseException):
    def __init__(self, signum: int):
        super().__init__(f"campaign interrupted by signal {signum}")
        self.signum = signum


class ResumeRefused(Exception):
    pass


def canonical(path: str | Path) -> Path:
    return Path(path).expanduser().resolve()


def require_safe_identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SAFE_IDENTIFIER.fullmatch(value) \
            or value in {".", ".."}:
        raise ValueError(f"{label} must match {SAFE_IDENTIFIER.pattern}: {value!r}")
    return value


def validate_provider_policy(raw: Any) -> dict[str, Any]:
    """Validate the campaign's fail-closed inference allowlist."""
    if not isinstance(raw, dict) or set(raw) != {
            "schema", "allowedProviders", "allowedModels"}:
        raise ValueError(
            "providerPolicy must contain exactly schema/allowedProviders/allowedModels")
    if raw.get("schema") != PROVIDER_POLICY_SCHEMA:
        raise ValueError(f"providerPolicy schema must be {PROVIDER_POLICY_SCHEMA}")
    providers = raw.get("allowedProviders")
    models = raw.get("allowedModels")
    if not isinstance(providers, list) or not providers:
        raise ValueError("providerPolicy.allowedProviders must be a non-empty array")
    for provider in providers:
        require_safe_identifier(provider, "allowed provider")
    if len(providers) != len(set(providers)):
        raise ValueError("providerPolicy.allowedProviders contains duplicates")
    if not isinstance(models, dict) or set(models) != set(providers):
        raise ValueError(
            "providerPolicy.allowedModels must have exactly one entry per allowed provider")
    for provider, provider_models in models.items():
        if not isinstance(provider_models, list) or not provider_models:
            raise ValueError(f"providerPolicy.allowedModels[{provider!r}] must be non-empty")
        for model in provider_models:
            require_safe_tool_name(model, f"allowed model for {provider}")
        if len(provider_models) != len(set(provider_models)):
            raise ValueError(f"providerPolicy.allowedModels[{provider!r}] contains duplicates")
    return raw


def parse_critic_identity(raw: str) -> tuple[str, str]:
    provider, separator, model = raw.partition(":")
    if not separator or not provider or not model:
        raise ValueError("critic must be an explicit provider:model identity")
    require_safe_identifier(provider, "critic provider")
    require_safe_tool_name(model, "critic model")
    return provider, model


def validate_inference_step(step: dict[str, Any], policy: dict[str, Any]) -> None:
    """Reject implicit or disallowed model routing before any campaign process starts."""
    inference = step.get("modelInference")
    if step.get("safety") == "subscription" and not isinstance(inference, bool):
        raise ValueError(
            f"step {step.get('id')}: subscription steps must declare modelInference true/false")
    if step.get("kind") in {"codex_repair_cobol", "kist_grow_tool"} \
            and inference is not True:
        raise ValueError(f"step {step.get('id')}: model-backed kind requires modelInference=true")
    if inference is not True:
        for field in ("provider", "authorModel", "critic", "reviewGrade"):
            if field in step:
                raise ValueError(
                    f"step {step.get('id')}: {field} is forbidden when modelInference is not true")
        return

    provider = step.get("provider")
    model = step.get("authorModel")
    if not isinstance(provider, str) or not provider:
        raise ValueError(f"step {step.get('id')}: provider must be explicit")
    if not isinstance(model, str) or not model:
        raise ValueError(f"step {step.get('id')}: authorModel must be explicit")
    allowed_providers = policy["allowedProviders"]
    allowed_models = policy["allowedModels"]
    if provider not in allowed_providers:
        raise ValueError(f"step {step.get('id')}: provider {provider!r} is not allowed")
    if model not in allowed_models[provider]:
        raise ValueError(
            f"step {step.get('id')}: model {model!r} is not allowed for {provider!r}")

    if step.get("kind") == "command":
        argv = step.get("argv")
        if not isinstance(argv, list):
            raise ValueError(f"step {step.get('id')}: model command requires argv")
        try:
            argv_provider = argv[argv.index("--provider") + 1]
            argv_model = argv[argv.index("--model") + 1]
        except (ValueError, IndexError):
            raise ValueError(
                f"step {step.get('id')}: model command must pin --provider and --model") from None
        if argv_provider != provider or argv_model != model:
            raise ValueError(
                f"step {step.get('id')}: command provider/model differs from its declaration")

    critic = step.get("critic")
    review_grade = step.get("reviewGrade")
    if critic is None:
        if review_grade is not None:
            raise ValueError(f"step {step.get('id')}: reviewGrade requires a critic")
        return
    if not isinstance(critic, str):
        raise ValueError(f"step {step.get('id')}: critic must be a string")
    critic_provider, critic_model = parse_critic_identity(critic)
    if critic_provider not in allowed_providers \
            or critic_model not in allowed_models[critic_provider]:
        raise ValueError(f"step {step.get('id')}: critic identity is not allowed")
    if critic_provider == provider and critic_model == model:
        if review_grade != "fresh_context_same_model":
            raise ValueError(
                f"step {step.get('id')}: same-model critic must be labeled "
                "fresh_context_same_model")
        if step.get("kind") == "kist_grow_tool" \
                and step.get("promotionExpectation") != "blocked_identity_distinct_reviewer":
            raise ValueError(
                f"step {step.get('id')}: same-model self-tool review must declare "
                "promotionExpectation=blocked_identity_distinct_reviewer")
    elif review_grade is not None:
        raise ValueError(
            f"step {step.get('id')}: unsupported reviewGrade {review_grade!r}")


def inference_identity(step: dict[str, Any]) -> dict[str, Any] | None:
    if step.get("modelInference") is not True:
        return None
    identity: dict[str, Any] = {
        "provider": step["provider"],
        "model": step["authorModel"],
    }
    if "critic" in step:
        critic_provider, critic_model = parse_critic_identity(step["critic"])
        same_identity = (
            critic_provider == step["provider"] and critic_model == step["authorModel"])
        identity["review"] = {
            "provider": critic_provider,
            "model": critic_model,
            "grade": step.get("reviewGrade") or "independent",
            "independent": not same_identity,
        }
    if "promotionExpectation" in step:
        identity["promotionExpectation"] = step["promotionExpectation"]
    return identity


def require_safe_tool_name(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SAFE_TOOL_NAME.fullmatch(value) \
            or value in {".", ".."}:
        raise ValueError(f"{label} is unsafe: {value!r}")
    return value


def require_safe_directory_name(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SAFE_DIRECTORY_NAME.fullmatch(value) \
            or value in {".", ".."}:
        raise ValueError(
            f"{label} must be one exact directory name matching "
            f"{SAFE_DIRECTORY_NAME.pattern}: {value!r}")
    return value


def require_resource_scope(value: Any) -> str:
    if not isinstance(value, str) or not value or len(value) > 1_024 \
            or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError(f"resource scope is unsafe: {value!r}")
    return value


def require_correlation_id(value: Any) -> str:
    if not isinstance(value, str) or not CORRELATION_ID.fullmatch(value):
        raise ValueError("correlation id must be exactly 64 lowercase hexadecimal characters")
    return value


def under(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def capture_file_binding(path: Path, label: str) -> dict[str, Any]:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"{label} is unavailable: {path}: {error}") from error
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode) or not resolved.is_file():
        raise ValueError(f"{label} is not a non-symlink regular file: {path}")
    return {
        "bindingPath": str(resolved),
        "bindingBytes": metadata.st_size,
        "bindingSHA256": sha256_file(resolved),
    }


def validate_file_binding(binding: Any, label: str) -> None:
    if not isinstance(binding, dict) or set(binding) != {
            "bindingPath", "bindingBytes", "bindingSHA256"}:
        raise ResumeRefused(f"{label} binding is malformed")
    raw_path = binding.get("bindingPath")
    if not isinstance(raw_path, str):
        raise ResumeRefused(f"{label} binding path is malformed")
    try:
        current = capture_file_binding(Path(raw_path), label)
    except ValueError as error:
        raise ResumeRefused(str(error)) from error
    if current != binding:
        raise ResumeRefused(f"{label} binding is stale: {raw_path}")


def validate_nested_file_bindings(value: Any) -> int:
    """Revalidate every explicit binding triple nested in a successful receipt."""
    verified = 0
    if isinstance(value, dict):
        binding_keys = {"bindingPath", "bindingBytes", "bindingSHA256"}
        present = binding_keys.intersection(value)
        if present:
            if present != binding_keys:
                raise ResumeRefused("successful receipt contains a partial file binding")
            validate_file_binding(
                {key: value[key] for key in binding_keys}, "successful receipt file")
            verified += 1
        for item in value.values():
            verified += validate_nested_file_bindings(item)
    elif isinstance(value, list):
        for item in value:
            verified += validate_nested_file_bindings(item)
    return verified


def capture_output_artifact(path: Path, label: str) -> dict[str, Any]:
    """Capture a non-symlink regular output using the standard receipt evidence keys."""
    binding = capture_file_binding(path, label)
    return {
        "path": binding["bindingPath"],
        "bytes": binding["bindingBytes"],
        "sha256": binding["bindingSHA256"],
    }


def normalize_tree_binding_spec(value: Any, label: str) -> tuple[str, list[str]]:
    if isinstance(value, str):
        path = value
        exclusions: Any = []
    elif isinstance(value, dict) and set(value) == {"path", "excludeDirectoryNames"}:
        path = value["path"]
        exclusions = value["excludeDirectoryNames"]
    else:
        raise ValueError(
            f"{label} must be a path string or path/excludeDirectoryNames object")
    if not isinstance(path, str) or not path:
        raise ValueError(f"{label} path must be a non-empty string")
    if not isinstance(exclusions, list) \
            or any(not isinstance(item, str) for item in exclusions):
        raise ValueError(f"{label} excludeDirectoryNames must be an array of exact names")
    for name in exclusions:
        require_safe_directory_name(name, f"{label} excluded directory name")
    if len(exclusions) != len(set(exclusions)):
        raise ValueError(f"{label} has duplicate excluded directory names")
    return path, sorted(exclusions)


def capture_tree_binding(path: Path, exclusions: list[str], label: str) -> dict[str, Any]:
    """Hash regular-file content and relative paths without following any tree symlink."""
    try:
        root_metadata = path.lstat()
        root = path.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"{label} tree is unavailable: {path}: {error}") from error
    if path.is_symlink() or not stat.S_ISDIR(root_metadata.st_mode) or not root.is_dir():
        raise ValueError(f"{label} tree is not a non-symlink directory: {path}")
    excluded = set(exclusions)
    digest = hashlib.sha256(b"kist.resume-tree.v1\0")
    file_count = 0
    total_bytes = 0

    def visit(directory: Path) -> None:
        nonlocal file_count, total_bytes
        try:
            with os.scandir(directory) as scanner:
                entries = sorted(scanner, key=lambda entry: os.fsencode(entry.name))
        except OSError as error:
            raise ValueError(f"{label} tree directory is unreadable: {directory}: {error}") from error
        try:
            for entry in entries:
                candidate = Path(entry.path)
                try:
                    metadata = entry.stat(follow_symlinks=False)
                except OSError as error:
                    raise ValueError(
                        f"{label} tree entry is unreadable: {candidate}: {error}") from error
                if stat.S_ISLNK(metadata.st_mode):
                    raise ValueError(f"{label} tree contains a symlink: {candidate}")
                if stat.S_ISDIR(metadata.st_mode):
                    if entry.name not in excluded:
                        visit(candidate)
                    continue
                if not stat.S_ISREG(metadata.st_mode):
                    raise ValueError(f"{label} tree contains a special file: {candidate}")
                relative = candidate.relative_to(root).as_posix()
                try:
                    relative_bytes = relative.encode("utf-8", errors="strict")
                except UnicodeError as error:
                    raise ValueError(
                        f"{label} tree path is not valid UTF-8: {candidate}") from error
                flags = os.O_RDONLY
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                try:
                    descriptor = os.open(candidate, flags)
                except OSError as error:
                    raise ValueError(f"{label} tree file is unreadable: {candidate}: {error}") from error
                try:
                    opened = os.fstat(descriptor)
                    if not stat.S_ISREG(opened.st_mode) \
                            or (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                        raise ValueError(f"{label} tree file changed during capture: {candidate}")
                    digest.update(b"F")
                    digest.update(len(relative_bytes).to_bytes(8, "big"))
                    digest.update(relative_bytes)
                    digest.update(opened.st_size.to_bytes(8, "big"))
                    captured = 0
                    while True:
                        chunk = os.read(descriptor, 1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
                        captured += len(chunk)
                    after = os.fstat(descriptor)
                    if captured != opened.st_size \
                            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
                                opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns):
                        raise ValueError(f"{label} tree file changed during capture: {candidate}")
                finally:
                    os.close(descriptor)
                file_count += 1
                total_bytes += captured
        finally:
            entries.clear()

    visit(root)
    return {
        "treePath": str(root),
        "excludeDirectoryNames": sorted(excluded),
        "fileCount": file_count,
        "treeBytes": total_bytes,
        "treeSHA256": digest.hexdigest(),
    }


def atomic_write_json(path: Path, value: Any) -> None:
    """Durably replace one JSON receipt without exposing a partial file."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    descriptor: int | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(temporary, flags, 0o600)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("short receipt write")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(temporary, path)
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory = os.open(path.parent, directory_flags)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


class CampaignRunLease:
    """Nonblocking output-directory ownership for one run or resume."""

    def __init__(self, output_dir: Path):
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self.path = output_dir / ".campaign.lock"
        self.descriptor = os.open(self.path, flags, 0o600)
        try:
            metadata = os.fstat(self.descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 \
                    or metadata.st_uid != os.geteuid():
                raise ResumeRefused("campaign lock is not a user-owned single-link regular file")
            os.fchmod(self.descriptor, 0o600)
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            os.close(self.descriptor)
            raise ResumeRefused("campaign output directory is already active") from error
        except Exception:
            os.close(self.descriptor)
            raise

    def release(self) -> None:
        if self.descriptor < 0:
            return
        fcntl.flock(self.descriptor, fcntl.LOCK_UN)
        os.close(self.descriptor)
        self.descriptor = -1

    def __enter__(self) -> CampaignRunLease:
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.release()


class ScopedResourceLeases:
    """Cross-campaign exclusive leases for shared mutable/live resources."""

    def __init__(self, scopes: list[str], timeout: float):
        self.scopes = sorted(set(scopes))
        self.timeout = max(0.1, timeout)
        self.descriptors: list[int] = []

    @staticmethod
    def root() -> Path:
        # Do not derive this coordination namespace from TMPDIR: two campaign processes with
        # different environments must still contend for the same machine-local resource lease.
        root = canonical("/tmp") / f"kist-capability-resource-leases-{os.geteuid()}"
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        metadata = root.lstat()
        if root.is_symlink() or not stat.S_ISDIR(metadata.st_mode) \
                or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
            raise ResumeRefused("shared resource lease directory is not private and user-owned")
        os.chmod(root, 0o700)
        return root

    def __enter__(self) -> ScopedResourceLeases:
        if not self.scopes:
            return self
        root = self.root()
        deadline = time.monotonic() + self.timeout
        try:
            for scope in self.scopes:
                require_resource_scope(scope)
                name = hashlib.sha256(scope.encode("utf-8")).hexdigest() + ".lock"
                flags = os.O_RDWR | os.O_CREAT
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                descriptor = os.open(root / name, flags, 0o600)
                metadata = os.fstat(descriptor)
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() \
                        or metadata.st_nlink != 1:
                    os.close(descriptor)
                    raise ResumeRefused(f"unsafe shared resource lease for {scope!r}")
                os.fchmod(descriptor, 0o600)
                while True:
                    try:
                        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            os.close(descriptor)
                            raise TimeoutError(f"timed out waiting for shared resource {scope!r}")
                        time.sleep(0.02)
                self.descriptors.append(descriptor)
            return self
        except BaseException:
            self.release()
            raise

    def release(self) -> None:
        for descriptor in reversed(self.descriptors):
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
        self.descriptors = []

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.release()


def install_signal_handlers() -> dict[int, Any]:
    previous: dict[int, Any] = {}

    def interrupt(signum: int, _frame: Any) -> None:
        raise CampaignInterrupted(signum)

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous[signum] = signal.getsignal(signum)
        signal.signal(signum, interrupt)
    return previous


def restore_signal_handlers(previous: dict[int, Any]) -> None:
    for signum, handler in previous.items():
        signal.signal(signum, handler)


def read_text(path: Path, limit: int = 128 * 1024) -> str:
    data = path.read_bytes()
    if len(data) > limit:
        data = data[-limit:]
    return data.decode("utf-8", errors="replace")


def expand(value: str, context: dict[str, str]) -> str:
    def replacement(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in context:
            raise ValueError(f"unknown context token ${{{key}}}")
        return context[key]

    result = TOKEN.sub(replacement, value)
    if "\0" in result:
        raise ValueError("NUL is forbidden in manifest values")
    return result


def expand_value(value: Any, context: dict[str, str]) -> Any:
    if isinstance(value, str):
        return expand(value, context)
    if isinstance(value, list):
        return [expand_value(item, context) for item in value]
    if isinstance(value, dict):
        return {str(key): expand_value(item, context) for key, item in value.items()}
    return value


def step_fingerprint(phase_id: str, step: dict[str, Any], context: dict[str, str]) -> str:
    return sha256_json({
        "campaignSchema": SCHEMA,
        "phase": phase_id,
        "step": expand_value(step, context),
    })


def resume_policy(step: dict[str, Any]) -> str:
    return str(step.get("resumePolicy", "reuse_only"))


def replay_is_explicitly_allowed(step: dict[str, Any]) -> bool:
    return resume_policy(step) in {"retry", "rerun"}


def passed_receipt_must_rerun(step: dict[str, Any]) -> bool:
    return resume_policy(step) == "rerun"


def resolved_resource_scopes(step: dict[str, Any], context: dict[str, str]) -> list[str]:
    # Read-only work never takes a shared exclusive lease, even if a manifest redundantly names one.
    if step["safety"] == "read_only":
        return []
    raw = step.get("resourceScopes", [])
    if raw:
        return sorted({require_resource_scope(expand(item, context)) for item in raw})
    if step["safety"] == "workspace_build":
        if step["kind"] == "command" and isinstance(step.get("cwd"), str):
            return [f"workspace:{canonical(expand(step['cwd'], context))}"]
        return [f"workspace:{canonical(context['KIST_REPO'])}"]
    if step["safety"] == "subscription":
        return ["subscription:global"]
    return ["live-control:global"]


def capture_resume_bindings(step: dict[str, Any], context: dict[str, str]) -> list[dict[str, Any]]:
    """Hash explicitly declared immutable inputs so a reused receipt binds current state."""
    raw = step.get("resumeBindings", [])
    if not isinstance(raw, list) or any(not isinstance(item, str) or not item for item in raw):
        raise ValueError("resumeBindings must be an array of non-empty paths")
    paths = [canonical(expand(item, context)) for item in raw]
    if len(paths) != len(set(paths)):
        raise ValueError("resumeBindings contains duplicate canonical paths")
    bindings: list[dict[str, Any]] = []
    for path in paths:
        bindings.append(capture_file_binding(path, "resume input"))
    return bindings


def capture_resume_tree_bindings(step: dict[str, Any],
                                 context: dict[str, str]) -> list[dict[str, Any]]:
    raw = step.get("resumeTreeBindings", [])
    if not isinstance(raw, list):
        raise ValueError("resumeTreeBindings must be an array")
    bindings: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, item in enumerate(raw):
        declared_path, exclusions = normalize_tree_binding_spec(
            item, f"resumeTreeBindings[{index}]")
        expanded_path = Path(expand(declared_path, context)).expanduser()
        binding = capture_tree_binding(expanded_path, exclusions, "resume input")
        if binding["treePath"] in seen:
            raise ValueError("resumeTreeBindings contains duplicate canonical paths")
        seen.add(binding["treePath"])
        bindings.append(binding)
    return bindings


def validate_resume_bindings(receipt: dict[str, Any], step: dict[str, Any],
                             context: dict[str, str]) -> None:
    try:
        expected = capture_resume_bindings(step, context)
    except ValueError as error:
        raise ResumeRefused(str(error)) from error
    recorded = receipt.get("resumeBindings", [])
    if recorded != expected:
        raise ResumeRefused("successful receipt has stale resumeBindings")


def validate_resume_tree_bindings(receipt: dict[str, Any], step: dict[str, Any],
                                  context: dict[str, str]) -> None:
    try:
        expected = capture_resume_tree_bindings(step, context)
    except ValueError as error:
        raise ResumeRefused(str(error)) from error
    recorded = receipt.get("resumeTreeBindings", [])
    if recorded != expected:
        raise ResumeRefused("successful receipt has stale resumeTreeBindings")


def receipt_path(output_dir: Path, step_id: str) -> Path:
    require_safe_identifier(step_id, "step id")
    return output_dir / f"{step_id}.receipt.json"


def attempt_receipt_path(output_dir: Path, step_id: str, attempt: int) -> Path:
    require_safe_identifier(step_id, "step id")
    if not isinstance(attempt, int) or attempt < 1:
        raise ValueError("attempt must be a positive integer")
    return output_dir / f"{step_id}.attempt-{attempt:04d}.receipt.json"


def prepare_step_directory(output_dir: Path, step_id: str, attempt: int) -> Path:
    """Create a private attempt directory without following resume-time symlinks."""
    require_safe_identifier(step_id, "step id")
    if not isinstance(attempt, int) or attempt < 1:
        raise ValueError("attempt must be a positive integer")
    parent = output_dir / step_id
    try:
        metadata = parent.lstat()
    except FileNotFoundError:
        parent.mkdir(mode=0o700)
        metadata = parent.lstat()
    if parent.is_symlink() or not stat.S_ISDIR(metadata.st_mode) \
            or metadata.st_uid != os.geteuid():
        raise ResumeRefused(f"unsafe step output directory: {parent}")
    os.chmod(parent, 0o700)
    attempt_dir = parent / f"attempt-{attempt:04d}"
    try:
        attempt_dir.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ResumeRefused(f"attempt output directory already exists: {attempt_dir}") from error
    metadata = attempt_dir.lstat()
    if attempt_dir.is_symlink() or not stat.S_ISDIR(metadata.st_mode) \
            or metadata.st_uid != os.geteuid():
        raise ResumeRefused(f"unsafe attempt output directory: {attempt_dir}")
    return attempt_dir


def validate_existing_step_directory(output_dir: Path, step_id: str) -> None:
    require_safe_identifier(step_id, "step id")
    parent = output_dir / step_id
    try:
        metadata = parent.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        raise ResumeRefused(f"step output directory is unavailable: {parent}: {error}") from error
    if parent.is_symlink() or not stat.S_ISDIR(metadata.st_mode) \
            or metadata.st_uid != os.geteuid():
        raise ResumeRefused(f"unsafe step output directory: {parent}")


def mcp_log_path(step_dir: Path, prefix: str, server_name: str) -> Path:
    require_safe_identifier(server_name, "MCP server name")
    require_safe_identifier(prefix, "MCP log prefix")
    return step_dir / f"{prefix}-{server_name}.stderr"


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        raise ResumeRefused(f"{label} is unreadable: {error}") from error
    if not isinstance(value, dict):
        raise ResumeRefused(f"{label} is not a JSON object")
    return value


def validate_hashed_artifacts(value: Any, output_dir: Path) -> int:
    """Re-hash every path/bytes/sha256 evidence triple nested in a receipt."""
    verified = 0
    if isinstance(value, dict):
        if {"path", "bytes", "sha256"}.issubset(value):
            raw_path, expected_bytes, expected_hash = value["path"], value["bytes"], value["sha256"]
            if not isinstance(raw_path, str) or not isinstance(expected_bytes, int) \
                    or not isinstance(expected_hash, str):
                raise ResumeRefused("successful receipt contains malformed hashed artifact evidence")
            candidate = Path(raw_path)
            try:
                metadata = candidate.lstat()
                resolved = candidate.resolve(strict=True)
            except OSError as error:
                raise ResumeRefused(f"successful receipt artifact is unavailable: {candidate}: {error}") from error
            if candidate.is_symlink() or not candidate.is_file() or not under(resolved, output_dir):
                raise ResumeRefused(f"successful receipt artifact escapes its output directory: {candidate}")
            if metadata.st_size != expected_bytes or sha256_file(resolved) != expected_hash:
                raise ResumeRefused(f"successful receipt artifact hash is stale: {candidate}")
            verified += 1
        for item in value.values():
            verified += validate_hashed_artifacts(item, output_dir)
    elif isinstance(value, list):
        for item in value:
            verified += validate_hashed_artifacts(item, output_dir)
    return verified


def validate_receipt_identity(receipt: dict[str, Any], phase_id: str, step: dict[str, Any],
                              context: dict[str, str], manifest_hash: str) -> None:
    expected = {
        "receiptSchema": STEP_RECEIPT_SCHEMA,
        "phase": phase_id,
        "step": step["id"],
        "kind": step["kind"],
        "safety": step["safety"],
        "manifestSHA256": manifest_hash,
        "stepFingerprint": step_fingerprint(phase_id, step, context),
        "runnerSHA256": context["RUNNER_SHA256"],
        "resumePolicy": resume_policy(step),
        "resourceScopes": resolved_resource_scopes(step, context),
    }
    model_identity = inference_identity(step)
    if model_identity is not None:
        expected["inference"] = model_identity
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise ResumeRefused(
                f"stale receipt for {phase_id}/{step['id']}: {key} does not match this run")
    if not isinstance(receipt.get("attempt"), int) or receipt["attempt"] < 1:
        raise ResumeRefused(f"stale receipt for {phase_id}/{step['id']}: invalid attempt")


def verify_reusable_receipt(receipt: dict[str, Any], phase_id: str, step: dict[str, Any],
                            context: dict[str, str], manifest_hash: str,
                            output_dir: Path) -> None:
    validate_receipt_identity(receipt, phase_id, step, context, manifest_hash)
    if receipt.get("status") != "passed":
        raise ResumeRefused(f"receipt for {phase_id}/{step['id']} is not successful")
    validate_resume_bindings(receipt, step, context)
    validate_resume_tree_bindings(receipt, step, context)
    if validate_nested_file_bindings(receipt) == 0:
        raise ResumeRefused(
            f"successful receipt for {phase_id}/{step['id']} has no current file binding")
    artifacts = validate_hashed_artifacts(receipt, output_dir)
    if step["kind"] in {"command", "cobol_heal", "codex_repair_cobol", "kist_grow_tool"} \
            and artifacts == 0:
        raise ResumeRefused(
            f"successful receipt for {phase_id}/{step['id']} has no re-verifiable log evidence")
    if step["kind"] == "command":
        if artifacts != 2:
            raise ResumeRefused(
                f"successful command receipt for {phase_id}/{step['id']} must bind exactly stdout and stderr")
        if not receipt.get("resumeBindings") and not receipt.get("resumeTreeBindings"):
            raise ResumeRefused(
                f"successful command receipt for {phase_id}/{step['id']} has no explicit resume binding")
        validate_file_binding(receipt.get("executableBinding"), "command executable")
        expected_cwd_path = canonical(expand(step["cwd"], context))
        expected_cwd = str(expected_cwd_path)
        expected_argv = [expand(str(item), context) for item in step["argv"]]
        expected_executable = resolve_executable(expected_argv[0], expected_cwd_path)
        recorded_argv = receipt.get("argv")
        exit_code = receipt.get("exitCode")
        stdout_evidence = receipt.get("stdout", {})
        stderr_evidence = receipt.get("stderr", {})
        expected_attempt_dir = output_dir / step["id"] / f"attempt-{receipt['attempt']:04d}"
        expected_stdout = str(expected_attempt_dir / "process.stdout")
        expected_stderr = str(expected_attempt_dir / "process.stderr")
        if not isinstance(recorded_argv, list) or not recorded_argv \
                or recorded_argv[1:] != expected_argv[1:] \
                or recorded_argv[0] != expected_executable \
                or receipt.get("executableBinding", {}).get("bindingPath") != recorded_argv[0] \
                or receipt.get("cwd") != expected_cwd \
                or not expected_cwd_path.is_dir() \
                or not isinstance(exit_code, int) or isinstance(exit_code, bool) \
                or receipt.get("timedOut") is not False \
                or stdout_evidence.get("path") != expected_stdout \
                or stderr_evidence.get("path") != expected_stderr \
                or receipt.get("failures") != []:
            raise ResumeRefused(
                f"successful command receipt for {phase_id}/{step['id']} has stale execution semantics")
        if expectation_failures(
                step.get("expect") or {}, exit_code,
                Path(stdout_evidence["path"]), Path(stderr_evidence["path"]), False):
            raise ResumeRefused(
                f"successful command receipt for {phase_id}/{step['id']} no longer satisfies expectations")
        cleanup = receipt.get("processCleanup")
        if not isinstance(cleanup, dict) or cleanup.get("groupGone") is not True:
            raise ResumeRefused(
                f"successful command receipt for {phase_id}/{step['id']} lacks process cleanup proof")
        expected_lease = {
            "exclusive": bool(resolved_resource_scopes(step, context)),
            "scopes": resolved_resource_scopes(step, context),
            "released": True,
        }
        if receipt.get("resourceLease") != expected_lease:
            raise ResumeRefused(
                f"successful command receipt for {phase_id}/{step['id']} lacks resource lease proof")
    if step["kind"] in {"mcp_inventory", "mcp_safe_calls", "mcp_unarmed_denial"}:
        validate_file_binding(receipt.get("configBinding"), "MCP configuration")


def load_manifest(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != SCHEMA:
        raise ValueError(f"manifest schema must be {SCHEMA}")
    provider_policy = validate_provider_policy(data.get("providerPolicy"))
    raw_context = data.get("context", {})
    if not isinstance(raw_context, dict):
        raise ValueError("manifest context must be an object")
    for key, value in raw_context.items():
        if not isinstance(key, str) or not CONTEXT_KEY.fullmatch(key) \
                or key in RESERVED_CONTEXT_KEYS or not isinstance(value, str) or not value:
            raise ValueError(f"manifest context entry is invalid or reserved: {key!r}")
    phases = data.get("phases")
    if not isinstance(phases, list) or not phases:
        raise ValueError("manifest phases must be a non-empty array")
    phase_ids: set[str] = set()
    step_ids: set[str] = set()
    for phase in phases:
        if not isinstance(phase, dict):
            raise ValueError("manifest phase entries must be objects")
        phase_id = phase.get("id")
        try:
            require_safe_identifier(phase_id, "phase id")
        except ValueError as error:
            raise ValueError(f"invalid phase id: {phase_id!r}") from error
        if phase_id in phase_ids:
            raise ValueError(f"invalid or duplicate phase id: {phase_id!r}")
        phase_ids.add(phase_id)
        steps = phase.get("steps", [])
        if not isinstance(steps, list):
            raise ValueError(f"phase {phase_id}: steps must be an array")
        for step in steps:
            if not isinstance(step, dict):
                raise ValueError(f"phase {phase_id}: step entries must be objects")
            step_id = step.get("id")
            kind = step.get("kind")
            safety = step.get("safety")
            try:
                require_safe_identifier(step_id, "step id")
            except ValueError as error:
                raise ValueError(f"invalid step id: {step_id!r}") from error
            if step_id in step_ids:
                raise ValueError(f"invalid or duplicate step id: {step_id!r}")
            if kind not in ALLOWED_KINDS:
                raise ValueError(f"step {step_id}: unsupported kind {kind!r}")
            if safety not in SAFETY_GRANTS:
                raise ValueError(f"step {step_id}: unsupported safety tier {safety!r}")
            if kind == "mcp_unarmed_denial" and safety != "read_only":
                raise ValueError(f"step {step_id}: mcp_unarmed_denial must be read_only")
            bindings = step.get("resumeBindings", [])
            if not isinstance(bindings, list) \
                    or any(not isinstance(item, str) or not item for item in bindings):
                raise ValueError(f"step {step_id}: resumeBindings must be an array of paths")
            tree_bindings = step.get("resumeTreeBindings", [])
            if not isinstance(tree_bindings, list):
                raise ValueError(f"step {step_id}: resumeTreeBindings must be an array")
            for index, tree_binding in enumerate(tree_bindings):
                normalize_tree_binding_spec(
                    tree_binding, f"step {step_id} resumeTreeBindings[{index}]")
            policy = step.get("resumePolicy", "reuse_only")
            if policy not in RESUME_POLICIES:
                raise ValueError(f"step {step_id}: unsupported resumePolicy {policy!r}")
            if policy in {"retry", "rerun"} and safety != "read_only":
                raise ValueError(
                    f"step {step_id}: {policy} resumePolicy is confined to read_only steps")
            if kind == "command" and policy == "retry" \
                    and not bindings and not tree_bindings:
                raise ValueError(
                    f"step {step_id}: retry commands require an explicit resume binding")
            validate_inference_step(step, provider_policy)
            scopes = step.get("resourceScopes", [])
            if not isinstance(scopes, list) or any(not isinstance(item, str) for item in scopes):
                raise ValueError(f"step {step_id}: resourceScopes must be an array of strings")
            for scope in scopes:
                require_resource_scope(scope)
            if len(scopes) != len(set(scopes)):
                raise ValueError(f"step {step_id}: duplicate resourceScopes")
            if kind == "codex_repair_cobol":
                perslis = step.get("perslisBinary")
                if perslis is not None and (not isinstance(perslis, str) or not perslis.strip()):
                    raise ValueError(
                        f"step {step_id}: perslisBinary must be a non-empty path string")
                for field in ("mcpConfig", "symbolicClaim"):
                    value = step.get(field)
                    if not isinstance(value, str) or not value.strip():
                        raise ValueError(
                            f"step {step_id}: {field} must be a non-empty string")
            if kind == "mcp_unarmed_denial":
                assertions = step.get("assertions")
                if not isinstance(assertions, list) or not assertions:
                    raise ValueError(f"step {step_id}: denial assertions must be a non-empty array")
                for assertion in assertions:
                    if not isinstance(assertion, dict) or set(assertion) != {
                            "server", "tool", "effect", "expected"}:
                        raise ValueError(
                            f"step {step_id}: denial assertions require exactly server/tool/effect/expected")
                    require_safe_identifier(assertion["server"], "denial MCP server name")
                    require_safe_tool_name(assertion["tool"], "denial MCP tool name")
                    if assertion["expected"] != "denied_unarmed" \
                            or not isinstance(assertion["effect"], str) \
                            or not assertion["effect"]:
                        raise ValueError(f"step {step_id}: denial assertion is not fail-closed")
            step_ids.add(step_id)
    return data


def process_group_alive(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_process(process: subprocess.Popen[Any], grace: float = 2.0,
                 owns_process_group: bool = True) -> dict[str, Any]:
    """Stop and verify the whole child group, even when its leader already exited."""
    term_sent = False
    kill_sent = False
    prior_mask: set[signal.Signals] | None = None
    if hasattr(signal, "pthread_sigmask"):
        # A second Ctrl-C/TERM must not interrupt the cleanup boundary half-way through.
        prior_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})

    def target_alive() -> bool:
        process.poll()  # reap the leader as soon as possible
        return process_group_alive(process.pid) if owns_process_group else process.poll() is None

    try:
        if target_alive():
            try:
                if owns_process_group:
                    os.killpg(process.pid, signal.SIGTERM)
                else:
                    process.terminate()
                term_sent = True
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + max(0.1, grace)
        while target_alive() and time.monotonic() < deadline:
            time.sleep(0.02)
        if target_alive():
            try:
                if owns_process_group:
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                kill_sent = True
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + max(0.1, grace)
            while target_alive() and time.monotonic() < deadline:
                time.sleep(0.02)
        if process.poll() is None:
            try:
                process.wait(timeout=max(0.1, grace))
            except subprocess.TimeoutExpired:
                process.kill()
                kill_sent = True
                process.wait(timeout=max(0.1, grace))
        return {
            "ownsProcessGroup": owns_process_group,
            "termSent": term_sent,
            "killSent": kill_sent,
            "groupGone": not target_alive(),
        }
    finally:
        if prior_mask is not None:
            signal.pthread_sigmask(signal.SIG_SETMASK, prior_mask)


def expectation_failures(expect: dict[str, Any], exit_code: int, stdout: Path, stderr: Path,
                         timed_out: bool) -> list[str]:
    failures: list[str] = []
    if timed_out:
        failures.append("process timed out")
    allowed = expect.get("exitCodes", [0])
    if exit_code not in allowed:
        failures.append(f"exit code {exit_code} not in {allowed}")
    combined = read_text(stdout) + "\n" + read_text(stderr)
    for needle in expect.get("combinedContains", []):
        if needle not in combined:
            failures.append(f"combined output missing {needle!r}")
    for needle in expect.get("combinedExcludes", []):
        if needle in combined:
            failures.append(f"combined output unexpectedly contains {needle!r}")
    return failures


def resolve_executable(argv0: str, cwd: Path) -> str | None:
    if os.path.isabs(argv0):
        candidate: str | None = argv0
    elif "/" in argv0:
        relative = canonical(cwd / argv0)
        candidate = str(relative) if relative.is_file() and os.access(relative, os.X_OK) else None
    else:
        candidate = shutil.which(argv0)
    if not candidate:
        return None
    resolved = canonical(candidate)
    return str(resolved) if resolved.is_file() and os.access(resolved, os.X_OK) else None


def run_process(argv: list[str], cwd: Path, timeout: int, step_dir: Path,
                expect: dict[str, Any] | None = None, label: str = "process",
                start_new_session: bool = True, stdin_text: str | None = None) -> dict[str, Any]:
    if not argv or any(not isinstance(arg, str) for arg in argv):
        raise ValueError("argv must be a non-empty string array")
    executable = resolve_executable(argv[0], cwd)
    if not executable:
        return {"status": "failed", "failures": [f"executable not found: {argv[0]}"], "argv": argv}
    argv = [executable, *argv[1:]]
    executable_binding = capture_file_binding(Path(executable), "command executable")
    stdout_path = step_dir / f"{label}.stdout"
    stderr_path = step_dir / f"{label}.stderr"
    started = time.time()
    timed_out = False
    cleanup: dict[str, Any] | None = None
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = subprocess.Popen(
            argv, cwd=str(cwd),
            stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
            stdout=stdout, stderr=stderr,
            start_new_session=start_new_session,
        )
        try:
            if stdin_text is None:
                exit_code = process.wait(timeout=timeout)
            else:
                process.communicate(input=stdin_text.encode("utf-8"), timeout=timeout)
                exit_code = process.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            cleanup = stop_process(process, owns_process_group=start_new_session)
            exit_code = process.returncode if process.returncode is not None else -signal.SIGKILL
        except BaseException:
            # SIGINT/SIGTERM is translated to CampaignInterrupted in the main thread. Always
            # terminate the isolated child group before unwinding to the receipt writer.
            stop_process(process, owns_process_group=start_new_session)
            raise
        if cleanup is None:
            # A successful parent may have left background descendants. Never carry them into the
            # next step; TERM then KILL any residual group and record the verified cleanup boundary.
            cleanup = stop_process(process, owns_process_group=start_new_session)
    failures = expectation_failures(expect or {}, exit_code, stdout_path, stderr_path, timed_out)
    if cleanup.get("groupGone") is not True:
        failures.append("residual child process group survived cleanup")
    return {
        "status": "passed" if not failures else "failed",
        "argv": argv,
        "cwd": str(cwd),
        "startedAt": started,
        "durationSeconds": round(time.time() - started, 3),
        "exitCode": exit_code,
        "timedOut": timed_out,
        "executableBinding": executable_binding,
        "processCleanup": cleanup,
        "stdout": {"path": str(stdout_path), "bytes": stdout_path.stat().st_size,
                   "sha256": sha256_file(stdout_path)},
        "stderr": {"path": str(stderr_path), "bytes": stderr_path.stat().st_size,
                   "sha256": sha256_file(stderr_path)},
        "failures": failures,
    }


class JSONRPCReader:
    """Read newline-delimited or Content-Length-framed JSON-RPC from one stdout pipe."""

    def __init__(self, pipe: Any):
        self.pipe = pipe
        self.buffer = bytearray()
        os.set_blocking(pipe.fileno(), False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(pipe, selectors.EVENT_READ)

    def _extract(self) -> dict[str, Any] | None:
        while self.buffer[:1] in (b"\n", b"\r", b" ", b"\t"):
            del self.buffer[:1]
        lower = bytes(self.buffer[:32]).lower()
        if lower.startswith(b"content-length:"):
            marker = self.buffer.find(b"\r\n\r\n")
            separator = 4
            if marker < 0:
                marker = self.buffer.find(b"\n\n")
                separator = 2
            if marker < 0:
                return None
            header = bytes(self.buffer[:marker]).decode("ascii", errors="replace")
            match = re.search(r"(?im)^content-length:\s*(\d+)\s*$", header)
            if not match:
                raise ValueError("invalid Content-Length frame")
            length = int(match.group(1))
            end = marker + separator + length
            if len(self.buffer) < end:
                return None
            payload = bytes(self.buffer[marker + separator:end])
            del self.buffer[:end]
        else:
            marker = self.buffer.find(b"\n")
            if marker < 0:
                return None
            payload = bytes(self.buffer[:marker]).strip()
            del self.buffer[:marker + 1]
            if not payload:
                return self._extract()
        value = json.loads(payload)
        return value if isinstance(value, dict) else None

    def response(self, request_id: int, timeout: int) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = self._extract()
            except json.JSONDecodeError:
                value = None
            if value is not None and value.get("id") == request_id:
                return value
            remaining = deadline - time.monotonic()
            events = self.selector.select(timeout=max(0, remaining))
            if not events:
                continue
            chunk = os.read(self.pipe.fileno(), 64 * 1024)
            if not chunk:
                raise EOFError("MCP server closed stdout before replying")
            self.buffer.extend(chunk)
            if len(self.buffer) > 8 * 1024 * 1024:
                raise ValueError("MCP response buffer exceeded 8 MiB")
        raise TimeoutError(f"MCP request {request_id} timed out")


def rpc_write(pipe: Any, value: dict[str, Any]) -> None:
    pipe.write(json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n")
    pipe.flush()


def validate_mcp_server_map(servers: Any) -> dict[str, Any]:
    if not isinstance(servers, dict):
        raise ValueError("MCP configuration contains no server map")
    for name, config in servers.items():
        require_safe_identifier(name, "MCP server name")
        if not isinstance(config, dict):
            raise ValueError(f"MCP server {name!r} configuration is not an object")
    return servers


def validate_expected_servers(raw: Any, servers: dict[str, Any]) -> list[str]:
    if not isinstance(raw, list) or any(not isinstance(item, str) for item in raw):
        raise ValueError("expectedServers must be an array of safe server names")
    for name in raw:
        require_safe_identifier(name, "expected MCP server name")
    if len(raw) != len(set(raw)):
        raise ValueError("expectedServers contains duplicates")
    return raw


def audit_mcp_tool_effect_catalog(server_name: str, config: dict[str, Any],
                                  advertised_tools: list[str]) -> dict[str, Any]:
    """Pure exact-set audit: every advertised MCP tool has one non-stale effect entry."""
    failures: list[str] = []
    try:
        require_safe_identifier(server_name, "MCP server name")
    except ValueError as error:
        failures.append(str(error))
    advertised: set[str] = set()
    for tool in advertised_tools:
        try:
            advertised.add(require_safe_tool_name(tool, "advertised MCP tool name"))
        except ValueError as error:
            failures.append(str(error))
    if len(advertised) != len(advertised_tools):
        failures.append("advertised MCP tool names are not unique")
    effects = config.get("toolEffects")
    declared: set[str] = set()
    if not isinstance(effects, dict):
        failures.append("MCP server has no explicit toolEffects object")
    else:
        for tool, effect in effects.items():
            try:
                declared.add(require_safe_tool_name(tool, "configured MCP tool name"))
            except ValueError as error:
                failures.append(str(error))
                continue
            if not isinstance(effect, str) or not effect:
                failures.append(f"configured MCP tool {tool!r} has no valid effect declaration")
    missing = sorted(advertised - declared)
    stale = sorted(declared - advertised)
    if missing:
        failures.append(f"advertised tools missing effect declarations: {missing}")
    if stale:
        failures.append(f"stale effect declarations for unadvertised tools: {stale}")
    return {
        "status": "passed" if not failures else "failed",
        "advertisedTools": sorted(advertised),
        "declaredTools": sorted(declared),
        "missingDeclarations": missing,
        "staleDeclarations": stale,
        "failures": failures,
    }


def probe_mcp_server(name: str, config: dict[str, Any], timeout: int, step_dir: Path) -> dict[str, Any]:
    try:
        require_safe_identifier(name, "MCP server name")
    except ValueError as error:
        return {"server": str(name), "status": "failed", "failure": str(error)}
    command = config.get("command")
    args = config.get("args", [])
    if not isinstance(command, str) or not isinstance(args, list):
        return {"server": name, "status": "failed", "failure": "invalid command/args"}
    executable = command if os.path.isabs(command) else shutil.which(command)
    if not executable:
        return {"server": name, "status": "failed", "failure": f"executable not found: {command}"}
    try:
        executable_binding = capture_file_binding(canonical(executable), f"MCP server {name} executable")
    except ValueError as error:
        return {"server": name, "status": "failed", "failure": str(error)}
    stderr_path = mcp_log_path(step_dir, "mcp", name)
    environment = os.environ.copy()
    environment.update({str(k): str(v) for k, v in config.get("env", {}).items()})
    process: subprocess.Popen[Any] | None = None
    started = time.time()
    try:
        with stderr_path.open("wb") as stderr:
            process = subprocess.Popen(
                [str(canonical(executable)), *map(str, args)], cwd=str(Path.home()), env=environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, start_new_session=True,
            )
            assert process.stdin is not None and process.stdout is not None
            reader = JSONRPCReader(process.stdout)
            rpc_write(process.stdin, {
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                           "clientInfo": {"name": "kist-capability-campaign", "version": "1"}},
            })
            initialized = reader.response(1, timeout)
            if "error" in initialized:
                raise RuntimeError(f"initialize error: {initialized['error']}")
            rpc_write(process.stdin, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
            rpc_write(process.stdin, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
            listed = reader.response(2, timeout)
            if "error" in listed:
                raise RuntimeError(f"tools/list error: {listed['error']}")
            tools = listed.get("result", {}).get("tools", [])
            if not isinstance(tools, list):
                raise RuntimeError("tools/list result did not contain a tools array")
            names = [tool.get("name") for tool in tools if isinstance(tool, dict)]
            if len(names) != len(tools) or any(not isinstance(item, str) or not item for item in names):
                raise RuntimeError("one or more MCP tools had no valid name")
            if len(set(names)) != len(names):
                raise RuntimeError("MCP tool names were not unique")
            protocol = initialized.get("result", {}).get("protocolVersion")
            catalog = audit_mcp_tool_effect_catalog(name, config, names)
            return {
                "server": name, "status": catalog["status"], "protocolVersion": protocol,
                "executableBinding": executable_binding,
                "toolCount": len(names), "toolNames": names,
                "effectCatalog": catalog,
                "failure": "; ".join(catalog["failures"]) if catalog["failures"] else None,
                "durationSeconds": round(time.time() - started, 3), "envKeys": sorted(config.get("env", {})),
            }
    except Exception as error:  # one server failure must not hide the remaining inventory
        return {"server": name, "status": "failed", "failure": str(error),
                "durationSeconds": round(time.time() - started, 3)}
    finally:
        if process is not None:
            stop_process(process)


def run_mcp_inventory(step: dict[str, Any], context: dict[str, str], step_dir: Path) -> dict[str, Any]:
    config_path = canonical(expand(step["config"], context))
    raw = json.loads(config_path.read_text(encoding="utf-8"))
    try:
        servers = validate_mcp_server_map(raw.get("mcpServers", raw))
        expected = validate_expected_servers(step.get("expectedServers", sorted(servers)), servers)
    except ValueError as error:
        return {"status": "failed", "config": str(config_path),
                "configBinding": capture_file_binding(config_path, "MCP configuration"),
                "failures": [str(error)]}
    failures: list[str] = []
    if set(servers) != set(expected):
        failures.append(f"configured server set {sorted(servers)} != expected {sorted(expected)}")
    results = [probe_mcp_server(name, servers[name], int(step.get("timeoutSeconds", 15)), step_dir)
               for name in expected if name in servers]
    failures.extend(f"{item['server']}: {item.get('failure', 'probe failed')}"
                    for item in results if item["status"] != "passed")
    total_tools = sum(item.get("toolCount", 0) for item in results)
    return {"status": "passed" if not failures else "failed", "config": str(config_path),
            "configBinding": capture_file_binding(config_path, "MCP configuration"),
            "serverCount": len(results), "toolCount": total_tools, "servers": results, "failures": failures}


def call_mcp_read_only_tool(name: str, config: dict[str, Any], call: dict[str, Any],
                            timeout: int, step_dir: Path) -> dict[str, Any]:
    try:
        require_safe_identifier(name, "MCP server name")
    except ValueError as error:
        return {"server": str(name), "status": "failed", "failure": str(error)}
    tool_name = call.get("tool")
    arguments = call.get("arguments", {})
    metadata = call.get("metadata")
    effects = config.get("toolEffects", {})
    if not isinstance(tool_name, str) or not tool_name or not isinstance(arguments, dict):
        return {"server": name, "status": "failed", "failure": "invalid tool call declaration"}
    if metadata is not None:
        try:
            if not isinstance(metadata, dict) or set(metadata) != {"kist.correlation_id"}:
                raise ValueError("MCP host metadata may contain only kist.correlation_id")
            require_correlation_id(metadata["kist.correlation_id"])
        except ValueError as error:
            return {"server": name, "tool": str(tool_name), "status": "failed",
                    "failure": str(error)}
    try:
        require_safe_tool_name(tool_name, "MCP tool name")
    except ValueError as error:
        return {"server": name, "tool": str(tool_name), "status": "failed", "failure": str(error)}
    if not isinstance(effects, dict) or effects.get(tool_name) != "readOnly":
        return {"server": name, "tool": tool_name, "status": "failed",
                "failure": "tool is not explicitly declared readOnly in MCP configuration"}
    command = config.get("command")
    args = config.get("args", [])
    if not isinstance(command, str) or not isinstance(args, list):
        return {"server": name, "tool": tool_name, "status": "failed",
                "failure": "invalid command/args"}
    executable = command if os.path.isabs(command) else shutil.which(command)
    if not executable:
        return {"server": name, "tool": tool_name, "status": "failed",
                "failure": f"executable not found: {command}"}
    try:
        executable_binding = capture_file_binding(canonical(executable), f"MCP server {name} executable")
    except ValueError as error:
        return {"server": name, "tool": tool_name, "status": "failed", "failure": str(error)}
    stderr_path = mcp_log_path(step_dir, "mcp-call", name)
    environment = os.environ.copy()
    environment.update({str(k): str(v) for k, v in config.get("env", {}).items()})
    process: subprocess.Popen[Any] | None = None
    started = time.time()
    try:
        with stderr_path.open("wb") as stderr:
            process = subprocess.Popen(
                [str(canonical(executable)), *map(str, args)], cwd=str(Path.home()), env=environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, start_new_session=True,
            )
            assert process.stdin is not None and process.stdout is not None
            reader = JSONRPCReader(process.stdout)
            rpc_write(process.stdin, {
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                           "clientInfo": {"name": "kist-capability-campaign", "version": "1"}},
            })
            initialized = reader.response(1, timeout)
            if "error" in initialized:
                raise RuntimeError(f"initialize error: {initialized['error']}")
            rpc_write(process.stdin, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
            rpc_write(process.stdin, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
            listed = reader.response(2, timeout)
            tools = listed.get("result", {}).get("tools", [])
            declared = {item.get("name") for item in tools if isinstance(item, dict)}
            if tool_name not in declared:
                raise RuntimeError(f"tools/list did not declare {tool_name}")
            call_params: dict[str, Any] = {"name": tool_name, "arguments": arguments}
            if metadata is not None:
                call_params["_meta"] = metadata
            rpc_write(process.stdin, {
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": call_params,
            })
            response = reader.response(3, timeout)
            encoded = json.dumps(response, sort_keys=True, separators=(",", ":"))
            result = response.get("result", {})
            tool_error = "error" in response or (isinstance(result, dict) and result.get("isError") is True)
            expected = call.get("expect", {})
            failures: list[str] = []
            if tool_error and not expected.get("allowToolError", False):
                failures.append("MCP tool returned an error")
            for needle in expected.get("contains", []):
                if needle not in encoded:
                    failures.append(f"MCP response missing {needle!r}")
            captured_json: dict[str, Any] | None = None
            if call.get("captureToolJSON") is True:
                try:
                    content = result.get("content") if isinstance(result, dict) else None
                    first = content[0] if isinstance(content, list) and content else None
                    text_value = first.get("text") if isinstance(first, dict) else None
                    parsed = json.loads(text_value) if isinstance(text_value, str) else None
                    if not isinstance(parsed, dict):
                        raise ValueError("tool content is not a JSON object")
                    captured_json = parsed
                except (IndexError, TypeError, ValueError, json.JSONDecodeError) as error:
                    failures.append(f"MCP tool JSON capture failed: {error}")
            receipt = {
                "server": name, "tool": tool_name,
                "status": "passed" if not failures else "failed",
                "executableBinding": executable_binding,
                "durationSeconds": round(time.time() - started, 3),
                "toolError": tool_error, "responseBytes": len(encoded.encode("utf-8")),
                "responseSHA256": hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
                "responsePreview": encoded[:2_048], "failures": failures,
            }
            if captured_json is not None:
                receipt["toolJSON"] = captured_json
            if metadata is not None:
                receipt["requestMetadata"] = metadata
            return receipt
    except Exception as error:
        return {"server": name, "tool": tool_name, "status": "failed", "failure": str(error),
                "durationSeconds": round(time.time() - started, 3)}
    finally:
        if process is not None:
            stop_process(process)


def run_mcp_safe_calls(step: dict[str, Any], context: dict[str, str], step_dir: Path) -> dict[str, Any]:
    config_path = canonical(expand(step["config"], context))
    raw = json.loads(config_path.read_text(encoding="utf-8"))
    try:
        servers = validate_mcp_server_map(raw.get("mcpServers", raw))
    except ValueError as error:
        return {"status": "failed", "config": str(config_path),
                "configBinding": capture_file_binding(config_path, "MCP configuration"),
                "failures": [str(error)]}
    raw_calls = step.get("calls", [])
    if not isinstance(raw_calls, list) or not raw_calls:
        return {"status": "failed", "failures": ["MCP config or safe-call declarations are invalid"]}
    calls = [expand_value(raw_call, context) for raw_call in raw_calls]
    failures: list[str] = []
    seen: set[str] = set()
    for call in calls:
        name = call.get("server") if isinstance(call, dict) else None
        tool = call.get("tool") if isinstance(call, dict) else None
        arguments = call.get("arguments", {}) if isinstance(call, dict) else None
        not_applicable = call.get("notApplicableReason") if isinstance(call, dict) else None
        try:
            require_safe_identifier(name, "safe-call MCP server name")
            require_safe_tool_name(tool, "safe-call MCP tool name")
        except ValueError as error:
            failures.append(str(error))
            continue
        if not isinstance(name, str) or name not in servers or name in seen:
            failures.append(f"invalid, missing, or duplicate safe-call server: {name!r}")
            continue
        if not isinstance(arguments, dict):
            failures.append(f"{name}/{tool}: arguments must be an object")
            continue
        if not_applicable is not None and (
                not isinstance(not_applicable, str) or not not_applicable.strip()
                or len(not_applicable) > 512):
            failures.append(f"{name}/{tool}: notApplicableReason must be bounded non-empty text")
            continue
        effects = servers[name].get("toolEffects", {})
        if not isinstance(effects, dict) or effects.get(tool) != "readOnly":
            failures.append(f"{name}/{tool}: tool is not explicitly declared readOnly")
            continue
        seen.add(name)
    try:
        expected = set(validate_expected_servers(step.get("expectedServers", list(servers)), servers))
    except ValueError as error:
        failures.append(str(error))
        expected = set()
    if seen != expected:
        failures.append(f"safe-call server set {sorted(seen)} != expected {sorted(expected)}")
    if failures:
        return {"status": "failed", "config": str(config_path),
                "configBinding": capture_file_binding(config_path, "MCP configuration"),
                "serverCount": 0, "calls": [], "failures": failures,
                "subprocessInvocations": 0}
    results: list[dict[str, Any]] = []
    for call in calls:
        name = call["server"]
        if call.get("notApplicableReason") is not None:
            results.append({
                "server": name, "tool": call["tool"], "status": "not_applicable",
                "reason": call["notApplicableReason"], "subprocessInvocations": 0,
            })
            continue
        result = call_mcp_read_only_tool(
            name, servers[name], call, int(step.get("timeoutSeconds", 30)), step_dir)
        results.append(result)
        if result["status"] != "passed":
            failures.append(
                f"{name}/{call.get('tool')}: {result.get('failure', result.get('failures'))}")
    return {"status": "passed" if not failures else "failed", "config": str(config_path),
            "configBinding": capture_file_binding(config_path, "MCP configuration"),
            "serverCount": len(results), "calls": results, "failures": failures}


def run_mcp_unarmed_denial(step: dict[str, Any], context: dict[str, str]) -> dict[str, Any]:
    """Validate static computer-use denial declarations. This function never launches a server."""
    config_path = canonical(expand(step["config"], context))
    raw = json.loads(config_path.read_text(encoding="utf-8"))
    binding = capture_file_binding(config_path, "MCP configuration")
    try:
        servers = validate_mcp_server_map(raw.get("mcpServers", raw))
    except ValueError as error:
        return {"status": "failed", "config": str(config_path), "configBinding": binding,
                "assertions": [], "failures": [str(error)], "subprocessInvocations": 0}
    declarations = expand_value(step.get("assertions", []), context)
    failures: list[str] = []
    results: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    if not isinstance(declarations, list) or not declarations:
        failures.append("denial assertions must be a non-empty array")
        declarations = []
    for declaration in declarations:
        if not isinstance(declaration, dict) or set(declaration) != {
                "server", "tool", "effect", "expected"}:
            failures.append("denial assertion must contain exactly server/tool/effect/expected")
            continue
        server = declaration["server"]
        tool = declaration["tool"]
        try:
            require_safe_identifier(server, "denial MCP server name")
            require_safe_tool_name(tool, "denial MCP tool name")
        except ValueError as error:
            failures.append(str(error))
            continue
        key = (server, tool)
        if key in seen:
            failures.append(f"duplicate denial assertion: {server}/{tool}")
            continue
        seen.add(key)
        if declaration["expected"] != "denied_unarmed":
            failures.append(f"{server}/{tool}: expected must be 'denied_unarmed'")
            continue
        config = servers.get(server)
        if config is None:
            failures.append(f"{server}/{tool}: server is absent from MCP configuration")
            continue
        effects = config.get("toolEffects", {})
        configured_effect = effects.get(tool) if isinstance(effects, dict) else None
        expected_effect = declaration["effect"]
        if configured_effect != expected_effect:
            failures.append(
                f"{server}/{tool}: configured effect {configured_effect!r} does not match "
                f"assertion {expected_effect!r}")
            continue
        has_server_policy = "computerUse" in config
        has_tool_policy = "computerUseTools" in config
        server_wide = config.get("computerUse", False)
        tool_scoped = config.get("computerUseTools", [])
        if has_server_policy and has_tool_policy:
            failures.append(f"{server}/{tool}: computer-use policies are mutually exclusive")
            continue
        if not isinstance(server_wide, bool) or not isinstance(tool_scoped, list) \
                or any(not isinstance(item, str) for item in tool_scoped) \
                or len(tool_scoped) != len(set(tool_scoped)):
            failures.append(f"{server}/{tool}: malformed computer-use metadata")
            continue
        try:
            for configured_tool in tool_scoped:
                require_safe_tool_name(configured_tool, "computer-use MCP tool name")
        except ValueError as error:
            failures.append(f"{server}/{tool}: {error}")
            continue
        protected_by = (
            "server" if server_wide is True
            else "tool" if tool in tool_scoped
            else None)
        if protected_by is None:
            failures.append(f"{server}/{tool}: tool is not explicitly computer-use protected")
            continue
        results.append({
            "server": server, "tool": tool, "effect": configured_effect,
            "expected": "denied_unarmed", "protectedBy": protected_by,
            "wouldDenyUnarmed": True,
        })
    return {
        "status": "passed" if not failures and len(results) == len(declarations) else "failed",
        "config": str(config_path), "configBinding": binding,
        "assertionCount": len(results), "assertions": results, "failures": failures,
        "subprocessInvocations": 0,
    }


BROKEN_COBOL = """       IDENTIFICATION DIVISION.
       PROGRAM-ID. KISTHEAL.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 A PIC 99 COMP-3 VALUE 19.
       01 B PIC 99 COMP-3 VALUE 23.
       01 TOTAL PIC 9(4) VALUE ZERO.
       PROCEDURE DIVISION.
           COMPUTE TOTAL = A +
           DISPLAY "KIST-COBOL-OK " TOTAL
           STOP RUN.
"""

FIXED_COBOL = BROKEN_COBOL.replace("COMPUTE TOTAL = A +\n", "COMPUTE TOTAL = A + B\n")

COBOL_VERIFY_MAKEFILE = """.PHONY: verify
verify:
\tmkdir -p .build
\tcobc -x -free -o .build/ledger ledger.cob
\t./.build/ledger | grep -F 'KIST-COBOL-OK 0042'
"""


def kist_author_options(step: dict[str, Any], context: dict[str, str]) -> list[str]:
    """Translate validated manifest model identities into literal Kist argv entries."""
    options: list[str] = []
    author_model = step.get("authorModel")
    critic = step.get("critic")
    review_grade = step.get("reviewGrade")
    if author_model is not None:
        options.extend(["--model", expand(author_model, context)])
    if critic is not None:
        options.extend(["--critic", expand(critic, context)])
    if review_grade is not None:
        options.extend(["--review-grade", expand(review_grade, context)])
    return options


def kist_disposable_builder_argv(
        step: dict[str, Any], context: dict[str, str], fixture: Path,
        prompt: str) -> list[str]:
    """Construct the narrow same-model Builder invocation exercised by self-heal."""
    return [
        expand(step["kistBinary"], context),
        "--provider", expand(step["provider"], context),
        "--tools", "text", "--budget", "200000",
        "--max-iterations", "12", "--headless", "--auto", "--fast", "--sandbox",
        *kist_author_options(step, context),
        "--project", str(fixture), prompt,
    ]


EVOLUTION_REVIEW_RECEIPT_PREFIX = "KIST_EVOLUTION_REVIEW_RECEIPT: "
BUILDER_REVIEW_RECEIPT_PREFIX = "KIST_BUILDER_REVIEW_RECEIPT: "


def verified_evolution_review_receipt(
        process_result: dict[str, Any], step: dict[str, Any],
        context: dict[str, str]) -> dict[str, Any]:
    """Validate Kist's actual reviewer invocation receipt, not manifest intent."""
    stdout = process_result.get("stdout", {})
    raw_path = stdout.get("path") if isinstance(stdout, dict) else None
    if not isinstance(raw_path, str):
        raise ValueError("self-tool run has no captured stdout artifact")
    receipts: list[dict[str, Any]] = []
    for line in Path(raw_path).read_text(encoding="utf-8", errors="strict").splitlines():
        if not line.startswith(EVOLUTION_REVIEW_RECEIPT_PREFIX):
            continue
        try:
            value = json.loads(line[len(EVOLUTION_REVIEW_RECEIPT_PREFIX):])
        except json.JSONDecodeError as error:
            raise ValueError(f"malformed Kist evolution review receipt: {error}") from error
        if not isinstance(value, dict):
            raise ValueError("Kist evolution review receipt must be a JSON object")
        receipts.append(value)
    if len(receipts) != 1:
        raise ValueError(f"expected exactly one Kist evolution review receipt, found {len(receipts)}")
    receipt = receipts[0]
    critic_provider, critic_model = parse_critic_identity(expand(step["critic"], context))
    expected_author = (
        f"{expand(step['provider'], context)}:{expand(step['authorModel'], context)}".lower())
    expected_critic = f"{critic_provider}:{critic_model}".lower()
    if expected_author == expected_critic:
        raise ValueError(
            "same-model review cannot authorize self-tool activation; "
            "an identity-distinct reviewer is required")
    required = {
        "activated": True,
        "outcome": "promoted",
        "grade": "independent",
        "independent": True,
        "authorIdentity": expected_author,
        "criticIdentity": expected_critic,
        "freshConversation": True,
        "separateInvocation": True,
    }
    for key, expected in required.items():
        if receipt.get(key) != expected:
            raise ValueError(
                f"Kist evolution review receipt {key}={receipt.get(key)!r}; expected {expected!r}")
    author_invocation = receipt.get("authorInvocationID")
    critic_invocation = receipt.get("criticInvocationID")
    if not isinstance(author_invocation, str) or not author_invocation \
            or not isinstance(critic_invocation, str) or not critic_invocation \
            or author_invocation == critic_invocation:
        raise ValueError("Kist evolution review receipt does not prove separate invocation identities")
    return receipt


def verified_builder_review_receipt(
        process_result: dict[str, Any], step: dict[str, Any],
        context: dict[str, str]) -> dict[str, Any]:
    """Validate the Builder's sealed same-model call provenance, not CLI intent flags."""
    stdout = process_result.get("stdout", {})
    raw_path = stdout.get("path") if isinstance(stdout, dict) else None
    if not isinstance(raw_path, str):
        raise ValueError("Builder run has no captured stdout artifact")
    receipts: list[dict[str, Any]] = []
    for line in Path(raw_path).read_text(encoding="utf-8", errors="strict").splitlines():
        if not line.startswith(BUILDER_REVIEW_RECEIPT_PREFIX):
            continue
        try:
            value = json.loads(line[len(BUILDER_REVIEW_RECEIPT_PREFIX):])
        except json.JSONDecodeError as error:
            raise ValueError(f"malformed Kist Builder review receipt: {error}") from error
        if not isinstance(value, dict):
            raise ValueError("Kist Builder review receipt must be a JSON object")
        receipts.append(value)
    if len(receipts) != 1:
        raise ValueError(f"expected exactly one Kist Builder review receipt, found {len(receipts)}")
    receipt = receipts[0]
    critic_provider, critic_model = parse_critic_identity(expand(step["critic"], context))
    expected_author = (
        f"{expand(step['provider'], context)}:{expand(step['authorModel'], context)}".lower())
    expected_critic = f"{critic_provider}:{critic_model}".lower()
    required = {
        "receiptType": "kist.builder-review",
        "schemaVersion": 1,
        "decision": "approve",
        "accepted": True,
        "grade": expand(step["reviewGrade"], context),
        "independent": False,
        "freshConversation": True,
        "separateInvocation": True,
        "reviewThreshold": 3,
        "producerIdentities": [expected_author],
        "reviewerIdentity": expected_critic,
        "invocationIDKind": "sealed_cli_telemetry_observation_id",
    }
    for key, expected in required.items():
        if receipt.get(key) != expected:
            raise ValueError(
                f"Kist Builder review receipt {key}={receipt.get(key)!r}; expected {expected!r}")
    producer_invocations = receipt.get("producerInvocationIDs")
    reviewer_invocations = receipt.get("reviewerInvocationIDs")
    for label, values in (("producerInvocationIDs", producer_invocations),
                          ("reviewerInvocationIDs", reviewer_invocations)):
        if not isinstance(values, list) or not values \
                or any(not isinstance(value, str) or not value for value in values) \
                or len(values) != len(set(values)):
            raise ValueError(
                f"Kist Builder review receipt {label} must be non-empty and unique")
    if not set(producer_invocations).isdisjoint(reviewer_invocations):
        raise ValueError(
            "Kist Builder review receipt producer/reviewer invocation identities overlap")
    evidence_digest = receipt.get("evidencePacketDigest")
    if not isinstance(evidence_digest, str) or not CORRELATION_ID.fullmatch(evidence_digest):
        raise ValueError(
            "Kist Builder review receipt evidencePacketDigest must be lowercase SHA-256")
    return receipt


def final_json_object(process_result: dict[str, Any], label: str) -> dict[str, Any]:
    """Parse a final stdout JSON object, including pretty-printed multiline output."""
    stdout = process_result.get("stdout", {})
    raw_path = stdout.get("path") if isinstance(stdout, dict) else None
    if not isinstance(raw_path, str):
        raise ValueError(f"{label} has no captured stdout artifact")
    output = Path(raw_path).read_text(encoding="utf-8", errors="strict")
    starts: list[int] = []
    offset = 0
    for line in output.splitlines(keepends=True):
        if line.lstrip(" \t").startswith("{"):
            starts.append(offset)
        offset += len(line)
    for start in reversed(starts):
        try:
            value = json.loads(output[start:])
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            raise ValueError(f"{label} final JSON value is not an object")
        return value
    raise ValueError(f"{label} final output does not end with a JSON object")


def perslis_cobol_vault_root() -> Path:
    override = os.environ.get("PERSLIS_APP_SUPPORT")
    application_support = (
        canonical(override) if override
        else canonical(Path.home() / "Library" / "Application Support" / "Perslis"))
    return application_support / "Vault" / "cobol"


def capture_perslis_reported_binary(reported: str, source: Path) -> dict[str, Any]:
    """Bind only the source-local oracle or Perslis's exact per-user COBOL Vault artifact."""
    if not isinstance(reported, str) or not reported or "\0" in reported:
        raise ValueError("Perslis run JSON reported an invalid compiled binary path")
    raw = Path(reported).expanduser()
    if not raw.is_absolute():
        raise ValueError("Perslis run JSON binary path must be absolute")
    if ".." in raw.parts:
        raise ValueError("Perslis run JSON binary path contains traversal")
    reported_path = raw
    try:
        metadata = reported_path.lstat()
        candidate = reported_path.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"Perslis compiled COBOL binary is unavailable: {error}") from error
    if reported_path.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise ValueError("Perslis compiled COBOL binary is not a non-symlink regular file")
    allowed_roots = [canonical(source.parent), canonical(perslis_cobol_vault_root())]
    # Perslis emits the binary directly in Vault/cobol (or, for a confined fixture host,
    # directly beside the source). Nested descendants are not part of either contract.
    allowed_root = next((root for root in allowed_roots if candidate.parent == root), None)
    if allowed_root is None:
        raise ValueError("Perslis reported a compiled binary outside its allowed COBOL roots")
    if candidate.name != source.stem:
        raise ValueError("Perslis reported binary name does not match the COBOL source stem")
    if not os.access(candidate, os.X_OK):
        raise ValueError("Perslis reported COBOL binary is not executable")
    artifact = capture_output_artifact(reported_path, "Perslis compiled COBOL binary")
    if artifact["path"] != str(candidate):
        raise ValueError("Perslis compiled binary binding does not match its reported path")
    return {"reportedPath": reported, "allowedRoot": str(allowed_root), **artifact}


def run_perslis_cobol_evidence(perslis_binary: str, source: Path, marker: str,
                               step_dir: Path) -> dict[str, Any]:
    """Require installed Perslis to independently detect and execute the repaired COBOL source."""
    if not os.path.isabs(perslis_binary):
        return {"status": "failed", "failures": ["perslisBinary must expand to an absolute path"]}
    perslis = canonical(perslis_binary)
    try:
        cli_binding = capture_file_binding(perslis, "Perslis executable")
    except ValueError as error:
        return {"status": "failed", "failures": [str(error)]}
    if not os.access(perslis, os.X_OK):
        return {"status": "failed", "perslisExecutableBinding": cli_binding,
                "failures": [f"Perslis executable is not executable: {perslis}"]}

    source = canonical(source)
    source_before = capture_output_artifact(source, "repaired COBOL source")
    detect = run_process(
        [str(perslis), "detect", str(source), "--json"], source.parent, 60, step_dir,
        {"exitCodes": [0]}, "perslis-detect")
    execute = run_process(
        [str(perslis), "run", str(source), "--json"], source.parent, 90, step_dir,
        {"exitCodes": [0]}, "perslis-run")
    failures: list[str] = []
    detect_json: dict[str, Any] | None = None
    run_json: dict[str, Any] | None = None
    if detect["status"] != "passed":
        failures.append(f"Perslis detect process failed: {detect.get('failures')}")
    if execute["status"] != "passed":
        failures.append(f"Perslis run process failed: {execute.get('failures')}")
    try:
        detect_json = final_json_object(detect, "Perslis detect")
        reported_source = detect_json.get("artifact_path")
        detected_source = (
            canonical(
                Path(reported_source) if Path(reported_source).is_absolute()
                else source.parent / reported_source)
            if isinstance(reported_source, str) else None)
        if detect_json.get("ok") is not True \
                or detect_json.get("mode") != "detect" \
                or str(detect_json.get("detected_engine", "")).lower() != "cobol" \
                or detected_source != source \
                or detect_json.get("artifact_sha256") != source_before["sha256"]:
            failures.append("Perslis detect JSON did not bind the repaired source as COBOL")
    except (OSError, UnicodeError, ValueError) as error:
        failures.append(str(error))
    try:
        run_json = final_json_object(execute, "Perslis run")
        captured_stdout = run_json.get("stdout")
        captured_bytes = (
            captured_stdout.encode("utf-8") if isinstance(captured_stdout, str) else None)
        exit_code = run_json.get("exit_code")
        compiler_exit_code = run_json.get("compiler_exit_code")
        if run_json.get("schema") != "perslis.run.v1" \
                or run_json.get("launched") is not True \
                or str(run_json.get("engine", "")).lower() != "cobol" \
                or run_json.get("status") != "completed" \
                or not isinstance(exit_code, int) or isinstance(exit_code, bool) or exit_code != 0 \
                or run_json.get("compiler_outcome") != "exited" \
                or not isinstance(compiler_exit_code, int) \
                or isinstance(compiler_exit_code, bool) or compiler_exit_code != 0 \
                or run_json.get("stdout_encoding") != "utf-8" \
                or run_json.get("stdout_complete") is not True \
                or run_json.get("stdout_truncated") is not False \
                or not isinstance(captured_stdout, str) or marker not in captured_stdout \
                or not isinstance(run_json.get("stdout_bytes"), int) \
                or isinstance(run_json.get("stdout_bytes"), bool) \
                or run_json.get("stdout_bytes") != len(captured_bytes or b"") \
                or run_json.get("stdout_sha256") != hashlib.sha256(
                    captured_bytes or b"").hexdigest():
            failures.append(
                "Perslis run JSON did not prove COBOL/completed/exit 0 with captured marker")
    except (OSError, UnicodeError, ValueError) as error:
        failures.append(str(error))

    source_after = capture_output_artifact(source, "repaired COBOL source")
    if source_after != source_before:
        failures.append("Perslis changed the repaired COBOL source")
    compiled_binary: dict[str, Any] | None = None
    if run_json is not None and isinstance(run_json.get("binary"), str):
        try:
            compiled_binary = capture_perslis_reported_binary(run_json["binary"], source)
        except (OSError, ValueError) as error:
            failures.append(str(error))
    else:
        failures.append("Perslis run JSON did not identify its compiled binary")
    return {
        "status": "passed" if not failures else "failed",
        "perslisExecutableBinding": cli_binding,
        "source": source_after,
        "compiledBinary": compiled_binary,
        "detect": detect,
        "detectJSON": detect_json,
        "run": execute,
        "runJSON": run_json,
        "failures": failures,
    }


def run_symbolic_claim_gate(step: dict[str, Any], context: dict[str, str],
                            step_dir: Path, mission_id: str) -> dict[str, Any]:
    """Require Perslis's fail-closed Jeeves seam before a model may mutate legacy source."""
    require_correlation_id(mission_id)
    config_path = canonical(expand(step["mcpConfig"], context))
    binding = capture_file_binding(config_path, "MCP configuration")
    failures: list[str] = []
    try:
        raw = json.loads(config_path.read_text(encoding="utf-8"))
        servers = validate_mcp_server_map(raw.get("mcpServers", raw))
        perslis_config = servers["perslis"]
    except (KeyError, OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        return {
            "status": "failed", "missionID": mission_id,
            "config": str(config_path), "configBinding": binding,
            "failures": [f"Perslis symbolic gate configuration failed: {error}"],
        }
    call = call_mcp_read_only_tool(
        "perslis", perslis_config,
        {
            "tool": "legacy_claim_gate",
            "arguments": {"claim": expand(step["symbolicClaim"], context)},
            "metadata": {"kist.correlation_id": mission_id},
            "captureToolJSON": True,
        },
        int(step.get("symbolicTimeoutSeconds", 60)), step_dir)
    if call.get("status") != "passed":
        failures.append(f"Perslis/Jeeves symbolic call failed: {call.get('failure') or call.get('failures')}")
    tool_json = call.get("toolJSON")
    if not isinstance(tool_json, dict) \
            or tool_json.get("verdict") != "allow" \
            or tool_json.get("may_proceed") is not True:
        failures.append("Perslis/Jeeves did not explicitly allow the concrete legacy claim")
    if not isinstance(tool_json, dict) or tool_json.get("correlation_id") != mission_id:
        failures.append("Perslis/Jeeves did not echo the host-owned mission correlation id")
    return {
        "status": "passed" if not failures else "failed",
        "missionID": mission_id,
        "claim": expand(step["symbolicClaim"], context),
        "config": str(config_path), "configBinding": binding,
        "call": call, "failures": failures,
    }


def run_cobol_heal(step: dict[str, Any], step_dir: Path) -> dict[str, Any]:
    fixture = step_dir / "fixture"
    fixture.mkdir()
    source = fixture / "heal.cob"
    source.write_text(BROKEN_COBOL, encoding="utf-8")
    bad = run_process(["cobc", "-x", "-free", "-o", "heal", "heal.cob"], fixture, 30, step_dir,
                      {"exitCodes": list(range(1, 256))}, "broken-compile")
    source.write_text(FIXED_COBOL, encoding="utf-8")
    fixed = run_process(["cobc", "-x", "-free", "-o", "heal", "heal.cob"], fixture, 30, step_dir,
                        {"exitCodes": [0]}, "fixed-compile")
    execution = run_process([str(fixture / "heal")], fixture, 10, step_dir,
                            {"exitCodes": [0], "combinedContains": ["KIST-COBOL-OK 0042"]}, "fixed-run")
    failures = []
    for label, result in [("broken failure detection", bad), ("fixed compile", fixed), ("fixed run", execution)]:
        if result["status"] != "passed":
            failures.append(f"{label} failed: {result.get('failures')}")
    source_artifact = capture_output_artifact(source, "healed COBOL source")
    binary_artifact = (
        capture_output_artifact(fixture / "heal", "healed COBOL binary")
        if (fixture / "heal").is_file() else None)
    if binary_artifact is None:
        failures.append("healed COBOL binary hash is unavailable")
    return {"status": "passed" if not failures else "failed", "fixture": str(fixture),
            "source": source_artifact, "binary": binary_artifact,
            "brokenCompile": bad, "fixedCompile": fixed, "fixedRun": execution, "failures": failures}


def run_codex_repair_cobol(step: dict[str, Any], context: dict[str, str], step_dir: Path) -> dict[str, Any]:
    fixture = step_dir / "codex-cobol-fixture"
    fixture.mkdir()
    source = fixture / "ledger.cob"
    source.write_text(BROKEN_COBOL.replace("KISTHEAL", "LEDGER"), encoding="utf-8")
    (fixture / "Makefile").write_text(COBOL_VERIFY_MAKEFILE, encoding="utf-8")
    original = sha256_file(source)
    mission_id = hashlib.sha256(os.urandom(32)).hexdigest()
    symbolic_gate = run_symbolic_claim_gate(step, context, step_dir, mission_id)
    if symbolic_gate["status"] != "passed":
        return {
            "status": "failed", "fixture": str(fixture), "missionID": mission_id,
            "sourceChanged": False,
            "source": capture_output_artifact(source, "unmodified broken COBOL source"),
            "symbolicGate": symbolic_gate,
            "agent": {"status": "not-run", "reason": "symbolic gate failed closed"},
            "failures": ["symbolic claim gate failed; Codex mutation was not started"],
        }
    prompt = (
        "This is a disposable COBOL repair fixture. Perslis and Jeeves already allowed the concrete "
        f"symbolic claim for mission {mission_id}; that is permission to test, not proof. "
        "Inspect ledger.cob, diagnose the real compiler failure, "
        "and make the smallest source fix. The complete deterministic verifier is `make verify`; use exactly "
        "that command to compile ledger.cob, run it, and require output KIST-COBOL-OK 0042. Do not replace "
        "the verifier with an inline shell expression. Use Kist tools; do not access paths "
        "outside this project, perform external or desktop actions, weaken the check, or stop at a plan."
    )
    agent = run_process(
        kist_disposable_builder_argv(step, context, fixture, prompt),
        canonical(context["KIST_REPO"]), int(step.get("timeoutSeconds", 900)), step_dir,
       {"exitCodes": [0]}, "codex-agent")
    changed = sha256_file(source) != original
    compile_result = run_process(["cobc", "-x", "-free", "-o", "ledger", "ledger.cob"], fixture, 30,
                                 step_dir, {"exitCodes": [0]}, "oracle-compile")
    if compile_result["status"] == "passed" and (fixture / "ledger").is_file():
        run_result = run_process([str(fixture / "ledger")], fixture, 10, step_dir,
                                 {"exitCodes": [0], "combinedContains": ["KIST-COBOL-OK 0042"]}, "oracle-run")
    else:
        run_result = {"status": "failed", "failures": ["compiled ledger binary is unavailable"]}
    failures = []
    review_receipt: dict[str, Any] | None = None
    if agent["status"] != "passed":
        failures.append(f"Codex/Kist run failed: {agent.get('failures')}")
    try:
        review_receipt = verified_builder_review_receipt(agent, step, context)
    except (OSError, UnicodeError, ValueError, KeyError) as error:
        failures.append(f"Codex/Kist Builder review evidence failed: {error}")
    if not changed:
        failures.append("Codex/Kist did not change the broken source")
    if compile_result["status"] != "passed":
        failures.append(f"held-out compile failed: {compile_result.get('failures')}")
    if run_result["status"] != "passed":
        failures.append(f"held-out execution failed: {run_result.get('failures')}")
    source_artifact: dict[str, Any] | None = None
    oracle_binary_artifact: dict[str, Any] | None = None
    try:
        source_artifact = capture_output_artifact(source, "repaired COBOL source")
    except ValueError as error:
        failures.append(str(error))
    binary = fixture / "ledger"
    if binary.is_file():
        try:
            oracle_binary_artifact = capture_output_artifact(binary, "held-out COBOL binary")
        except ValueError as error:
            failures.append(str(error))
    else:
        failures.append("held-out COBOL binary hash is unavailable")

    perslis_result: dict[str, Any] | None = None
    if step.get("perslisBinary") is not None:
        perslis_result = run_perslis_cobol_evidence(
            expand(step["perslisBinary"], context), source, "KIST-COBOL-OK 0042", step_dir)
        if perslis_result["status"] != "passed":
            failures.append(f"Perslis held-out execution failed: {perslis_result.get('failures')}")
    return {"status": "passed" if not failures else "failed", "fixture": str(fixture),
            "missionID": mission_id, "symbolicGate": symbolic_gate,
            "sourceChanged": changed, "source": source_artifact,
            "oracleBinary": oracle_binary_artifact, "agent": agent,
            "reviewReceipt": review_receipt,
            "oracleCompile": compile_result, "oracleRun": run_result,
            "perslis": perslis_result, "failures": failures}


def run_kist_grow_tool(step: dict[str, Any], context: dict[str, str], step_dir: Path) -> dict[str, Any]:
    fixture = step_dir / "self-tool-fixture"
    fixture.mkdir()
    if step.get("promotionExpectation") == "blocked_identity_distinct_reviewer":
        # Codex/GPT-only mode has one model lineage. Spending a subscription call cannot manufacture
        # identity-distinct promotion authority, so record the honest blocked state without invoking Kist.
        return {
            "status": "skipped",
            "reason": "blocked_identity_distinct_reviewer",
            "fixture": str(fixture),
            "activationExpected": False,
            "activatedToolCount": 0,
            "author": {
                "status": "not-run",
                "reason": "same-model review is advisory and cannot activate a self-authored tool",
            },
            "reviewReceipt": None,
            "reload": {"status": "not-run", "reason": "no activation was authorized"},
            "failures": [],
        }
    kist = expand(step["kistBinary"], context)
    capability = step.get(
        "capability",
        "Parse a comma-separated list of signed integers, reject non-integers, sort ascending, and print one comma-separated line.")
    author = run_process([
        kist, "--provider", expand(step["provider"], context),
        "--tools", "text", "--budget", "200000",
        "--max-iterations", "12", "--fast", "--yolo", "--sandbox",
        *kist_author_options(step, context), "--project", str(fixture),
    ], canonical(context["KIST_REPO"]), int(step.get("timeoutSeconds", 1200)), step_dir,
       {"exitCodes": [0], "combinedContains": ["ACTIVATED self__", "smoke:"]},
       "grow-agent",
       stdin_text=f"/grow {capability}\n/quit\n")
    store = fixture / ".kist" / "self-tools"
    homes = sorted(path for path in store.glob("self__*") if path.is_dir()) if store.is_dir() else []
    failures: list[str] = []
    review_receipt: dict[str, Any] | None = None
    if author["status"] != "passed":
        failures.append(f"live /grow failed: {author.get('failures')}")
    try:
        review_receipt = verified_evolution_review_receipt(author, step, context)
    except (OSError, UnicodeError, ValueError, KeyError) as error:
        failures.append(f"live /grow review evidence failed: {error}")
    if len(homes) != 1:
        failures.append(f"expected exactly one activated self__ tool, found {len(homes)}")
    manifest_summary: dict[str, Any] | None = None
    tool_name: str | None = None
    if len(homes) == 1:
        try:
            raw = json.loads((homes[0] / "manifest.json").read_text(encoding="utf-8"))
            tool_name = raw.get("name")
            script_file = raw.get("scriptFile")
            if tool_name != homes[0].name or not isinstance(script_file, str) or "/" in script_file:
                raise ValueError("manifest identity or scriptFile is not confined")
            script = homes[0] / script_file
            if not script.is_file():
                raise ValueError("activated script is missing")
            expected = raw.get("testExpectSubstring")
            if not isinstance(expected, str) or not expected.strip():
                raise ValueError("activation has no non-empty smoke expectation")
            manifest_summary = {
                "name": tool_name, "parameterCount": len(raw.get("parameters", [])),
                "manifestSHA256": sha256_file(homes[0] / "manifest.json"),
                "scriptSHA256": sha256_file(script), "smokeExpectation": expected,
                "manifest": capture_output_artifact(
                    homes[0] / "manifest.json", "self-tool manifest"),
                "script": capture_output_artifact(script, "self-tool script"),
            }
        except Exception as error:
            failures.append(f"activated tool validation failed: {error}")
    reload_result: dict[str, Any]
    if tool_name:
        reload_result = run_process([
            kist, "--provider", expand(step["provider"], context),
            "--fast", *kist_author_options(step, context),
            "--project", str(fixture),
        ], canonical(context["KIST_REPO"]), 60, step_dir,
           {"exitCodes": [0], "combinedContains": ["self-evolved", tool_name]},
           "reload", stdin_text="/quit\n")
        if reload_result["status"] != "passed":
            failures.append(f"activated tool did not reload: {reload_result.get('failures')}")
    else:
        reload_result = {"status": "failed", "failures": ["no activated tool to reload"]}
    return {"status": "passed" if not failures else "failed", "fixture": str(fixture),
            "tool": manifest_summary, "reviewReceipt": review_receipt,
            "author": author, "reload": reload_result,
            "failures": failures}


def invocation_contract(args: argparse.Namespace, selected_phases: set[str],
                        selected_steps: set[str]) -> dict[str, Any]:
    return {
        "phases": sorted(selected_phases),
        "steps": sorted(selected_steps),
        "allowWorkspaceBuilds": bool(args.allow_workspace_builds),
        "allowSubscription": bool(args.allow_subscription),
        "allowLiveControl": bool(args.allow_live_control),
        "dryRun": bool(args.dry_run),
    }


def replace_campaign_step(campaign: dict[str, Any], receipt: dict[str, Any]) -> None:
    steps = campaign.setdefault("steps", [])
    for index, existing in enumerate(steps):
        if existing.get("step") == receipt["step"]:
            steps[index] = receipt
            return
    steps.append(receipt)


def write_campaign_state(output_dir: Path, campaign: dict[str, Any]) -> None:
    campaign["updatedAt"] = time.time()
    atomic_write_json(output_dir / "campaign.receipt.json", campaign)


def write_step_state(output_dir: Path, campaign: dict[str, Any],
                     receipt: dict[str, Any], keep_history: bool = False) -> None:
    # The current step file lands first. If power is lost before the aggregate replacement,
    # resume can recover this newer terminal receipt instead of replaying the step.
    atomic_write_json(receipt_path(output_dir, receipt["step"]), receipt)
    replace_campaign_step(campaign, receipt)
    write_campaign_state(output_dir, campaign)
    if keep_history:
        atomic_write_json(
            attempt_receipt_path(output_dir, receipt["step"], receipt["attempt"]), receipt)


def dispatch_step(step: dict[str, Any], context: dict[str, str], step_dir: Path,
                  allowed_roots: list[Path]) -> dict[str, Any]:
    if step["kind"] == "command":
        cwd = canonical(expand(step["cwd"], context))
        if not any(under(cwd, root) for root in allowed_roots):
            raise ValueError(f"cwd outside declared roots: {cwd}")
        argv = [expand(str(item), context) for item in step["argv"]]
        return run_process(argv, cwd, int(step.get("timeoutSeconds", 600)), step_dir,
                           step.get("expect"))
    if step["kind"] == "mcp_inventory":
        return run_mcp_inventory(step, context, step_dir)
    if step["kind"] == "mcp_safe_calls":
        return run_mcp_safe_calls(step, context, step_dir)
    if step["kind"] == "mcp_unarmed_denial":
        return run_mcp_unarmed_denial(step, context)
    if step["kind"] == "cobol_heal":
        return run_cobol_heal(step, step_dir)
    if step["kind"] == "codex_repair_cobol":
        return run_codex_repair_cobol(step, context, step_dir)
    if step["kind"] == "kist_grow_tool":
        return run_kist_grow_tool(step, context, step_dir)
    raise ValueError(f"unreachable kind: {step['kind']}")


def validate_resume_state(campaign: dict[str, Any], manifest: dict[str, Any], manifest_path: Path,
                          manifest_hash: str, output_dir: Path,
                          invocation: dict[str, Any], runner_hash: str) -> None:
    expected = {
        "runStateSchema": RUN_STATE_SCHEMA,
        "schema": SCHEMA,
        "manifest": str(manifest_path),
        "manifestSHA256": manifest_hash,
        "runnerSHA256": runner_hash,
        "providerPolicy": manifest["providerPolicy"],
        "outputDirectory": str(output_dir),
        "invocation": invocation,
    }
    for key, value in expected.items():
        if campaign.get(key) != value:
            raise ResumeRefused(f"campaign resume contract mismatch: {key}")
    steps = campaign.get("steps")
    if not isinstance(steps, list) or any(not isinstance(item, dict) for item in steps):
        raise ResumeRefused("campaign resume state has an invalid step ledger")
    identities = [item.get("step") for item in steps]
    if any(not isinstance(identity, str) for identity in identities):
        raise ResumeRefused("campaign resume state has a malformed step identity")
    if len(identities) != len(set(identities)):
        raise ResumeRefused("campaign resume state has duplicate step receipts")
    selected_phases = set(invocation["phases"])
    selected_steps = set(invocation["steps"])
    expected_steps = {
        step["id"]
        for phase in manifest["phases"] if phase["id"] in selected_phases
        for step in phase.get("steps", [])
        if not selected_steps or step["id"] in selected_steps
    }
    unexpected = set(identities) - expected_steps
    if unexpected:
        raise ResumeRefused(
            f"campaign resume state has unexpected step receipts: {sorted(unexpected, key=str)}")


def prior_step_receipt(campaign: dict[str, Any], output_dir: Path, phase_id: str,
                       step: dict[str, Any], context: dict[str, str],
                       manifest_hash: str) -> dict[str, Any] | None:
    aggregate = next(
        (item for item in campaign.get("steps", []) if item.get("step") == step["id"]), None)
    path = receipt_path(output_dir, step["id"])
    if not path.exists():
        if aggregate is not None:
            raise ResumeRefused(f"step receipt is missing for {phase_id}/{step['id']}")
        return None
    current = load_json_object(path, f"step receipt {step['id']}")
    validate_receipt_identity(current, phase_id, step, context, manifest_hash)
    if aggregate is None:
        return current
    validate_receipt_identity(aggregate, phase_id, step, context, manifest_hash)
    if current == aggregate:
        return current
    # Atomic ordering deliberately writes the current receipt before the aggregate. This is the
    # only admissible split-brain: a terminal receipt is newer than the same running attempt.
    if aggregate.get("status") == "running" \
            and aggregate.get("attempt") == current.get("attempt") \
            and current.get("status") in {"passed", "failed", "interrupted", "skipped"}:
        replace_campaign_step(campaign, current)
        return current
    raise ResumeRefused(f"step and campaign receipts disagree for {phase_id}/{step['id']}")


def preflight_resume_receipts(campaign: dict[str, Any], manifest: dict[str, Any],
                              output_dir: Path, context: dict[str, str],
                              manifest_hash: str, selected_phases: set[str],
                              selected_steps: set[str]) -> None:
    """Validate the complete old ledger before executing or rewriting any campaign state."""
    for phase in manifest["phases"]:
        if phase["id"] not in selected_phases:
            continue
        for step in phase.get("steps", []):
            if selected_steps and step["id"] not in selected_steps:
                continue
            prior = prior_step_receipt(
                campaign, output_dir, phase["id"], step, context, manifest_hash)
            if prior is None:
                continue
            if prior.get("status") != "skipped":
                validate_existing_step_directory(output_dir, step["id"])
            status = prior.get("status")
            if status == "passed":
                if not passed_receipt_must_rerun(step):
                    verify_reusable_receipt(
                        prior, phase["id"], step, context, manifest_hash, output_dir)
            elif status == "skipped":
                continue
            elif status not in {"running", "failed", "interrupted"}:
                raise ResumeRefused(
                    f"step {phase['id']}/{step['id']} has unknown prior status {status!r}")
            elif not replay_is_explicitly_allowed(step):
                raise ResumeRefused(
                    f"step {phase['id']}/{step['id']} ended {status}; resumePolicy "
                    f"does not explicitly permit replay")
            elif resume_policy(step) == "retry":
                # Retry means the same read-only attempt inputs. `rerun` is the distinct policy
                # that intentionally refreshes changed external state and captures new bindings.
                validate_resume_bindings(prior, step, context)
                validate_resume_tree_bindings(prior, step, context)
                validate_nested_file_bindings(prior)


def run_selected_campaign(manifest: dict[str, Any], manifest_path: Path, manifest_hash: str,
                          output_dir: Path, context: dict[str, str], allowed_roots: list[Path],
                          selected_phases: set[str], selected_steps: set[str],
                          grants: dict[str, Any], campaign: dict[str, Any],
                          resume: bool) -> int:
    active: tuple[str, dict[str, Any], dict[str, Any]] | None = None
    try:
        if resume:
            preflight_resume_receipts(
                campaign, manifest, output_dir, context, manifest_hash,
                selected_phases, selected_steps)
        campaign["status"] = "running"
        campaign.pop("finishedAt", None)
        if resume:
            campaign.setdefault("resumedAt", []).append(time.time())
        write_campaign_state(output_dir, campaign)

        for phase in manifest["phases"]:
            phase_id = phase["id"]
            if phase_id not in selected_phases:
                continue
            for step in phase.get("steps", []):
                if selected_steps and step["id"] not in selected_steps:
                    continue
                prior = prior_step_receipt(
                    campaign, output_dir, phase_id, step, context, manifest_hash) if resume else None
                if prior is not None and prior.get("status") == "passed" \
                        and not passed_receipt_must_rerun(step):
                    verify_reusable_receipt(
                        prior, phase_id, step, context, manifest_hash, output_dir)
                    replace_campaign_step(campaign, prior)
                    print(f"REUSED  {phase_id}/{step['id']}")
                    continue
                if prior is not None and prior.get("status") == "skipped":
                    replace_campaign_step(campaign, prior)
                    print(f"REUSED  {phase_id}/{step['id']} (skipped)")
                    continue
                if prior is not None:
                    status = prior.get("status")
                    if status == "passed" and passed_receipt_must_rerun(step):
                        pass
                    elif status not in {"running", "failed", "interrupted"}:
                        raise ResumeRefused(
                            f"step {phase_id}/{step['id']} has unknown prior status {status!r}")
                    elif not replay_is_explicitly_allowed(step):
                        raise ResumeRefused(
                            f"step {phase_id}/{step['id']} ended {status}; resumePolicy "
                            f"does not explicitly permit replay")
                attempt = (prior.get("attempt", 0) if prior else 0) + 1
                identity = {
                    "receiptSchema": STEP_RECEIPT_SCHEMA,
                    "manifestSHA256": manifest_hash,
                    "stepFingerprint": step_fingerprint(phase_id, step, context),
                    "runnerSHA256": context["RUNNER_SHA256"],
                    "resumePolicy": resume_policy(step),
                    "resourceScopes": resolved_resource_scopes(step, context),
                    "phase": phase_id,
                    "step": step["id"],
                    "kind": step["kind"],
                    "safety": step["safety"],
                    "attempt": attempt,
                }
                model_identity = inference_identity(step)
                if model_identity is not None:
                    identity["inference"] = model_identity
                required = SAFETY_GRANTS[step["safety"]]
                if required and not grants.get(required, False):
                    receipt = {**identity, "status": "skipped",
                               "reason": f"requires --{required.replace('_', '-')}"}
                    write_step_state(output_dir, campaign, receipt, keep_history=True)
                    print(f"SKIPPED {phase_id}/{step['id']}")
                    continue
                if grants.get("dry_run", False):
                    receipt = {**identity, "status": "skipped", "reason": "dry run"}
                    write_step_state(output_dir, campaign, receipt, keep_history=True)
                    print(f"SKIPPED {phase_id}/{step['id']}")
                    continue

                try:
                    input_bindings = capture_resume_bindings(step, context)
                    tree_bindings = capture_resume_tree_bindings(step, context)
                except ValueError as error:
                    receipt = {
                        **identity, "resumeBindings": [], "resumeTreeBindings": [],
                        "status": "failed",
                        "startedAt": time.time(), "finishedAt": time.time(),
                        "failures": [str(error)],
                    }
                    write_step_state(output_dir, campaign, receipt, keep_history=True)
                    print(f"FAILED  {phase_id}/{step['id']}")
                    continue
                running = {
                    **identity,
                    "resumeBindings": input_bindings,
                    "resumeTreeBindings": tree_bindings,
                    "status": "running", "startedAt": time.time(),
                }
                active = (phase_id, step, running)
                write_step_state(output_dir, campaign, running)
                try:
                    step_dir = prepare_step_directory(output_dir, step["id"], attempt)
                    scopes = identity["resourceScopes"]
                    lease_timeout = float(step.get(
                        "resourceLeaseTimeoutSeconds", step.get("timeoutSeconds", 600)))
                    with ScopedResourceLeases(scopes, lease_timeout):
                        result = dispatch_step(step, context, step_dir, allowed_roots)
                    result["resourceLease"] = {
                        "exclusive": bool(scopes), "scopes": scopes, "released": True,
                    }
                except CampaignInterrupted:
                    raise
                except Exception as error:
                    result = {"status": "failed", "failures": [str(error)]}
                # Preserve the immutable-input bindings captured immediately before execution.
                # They are deliberately not recaptured after a mutating command has run.
                receipt = {
                    **running, **result, **identity,
                    "resumeBindings": running["resumeBindings"],
                    "resumeTreeBindings": running["resumeTreeBindings"],
                    "finishedAt": time.time(),
                }
                write_step_state(output_dir, campaign, receipt, keep_history=True)
                active = None
                print(f"{receipt['status'].upper():7} {phase_id}/{step['id']}")

        campaign["finishedAt"] = time.time()
        statuses = [step.get("status") for step in campaign["steps"]]
        if any(status == "failed" for status in statuses):
            campaign["status"] = "failed"
        elif not statuses or any(status == "skipped" for status in statuses):
            campaign["status"] = "incomplete"
        elif all(status == "passed" for status in statuses):
            campaign["status"] = "passed"
        else:
            campaign["status"] = "incomplete"
        write_campaign_state(output_dir, campaign)
        campaign_path = output_dir / "campaign.receipt.json"
        print(f"{campaign['status'].upper()} receipt={campaign_path}")
        return 0 if campaign["status"] == "passed" else 1
    except CampaignInterrupted as interruption:
        if active is not None:
            phase_id, step, running = active
            # A signal can land between the atomic current-receipt replacement and the aggregate
            # replacement. If the current file is already terminal, preserve it: the step finished
            # and replaying it would be less safe than recovering the newer receipt.
            terminal: dict[str, Any] | None = None
            try:
                candidate = load_json_object(
                    receipt_path(output_dir, step["id"]), f"step receipt {step['id']}")
                if candidate.get("attempt") == running["attempt"] \
                        and candidate.get("status") in {"passed", "failed", "skipped"}:
                    terminal = candidate
            except ResumeRefused:
                terminal = None
            if terminal is not None:
                replace_campaign_step(campaign, terminal)
            else:
                interrupted = {
                    **running,
                    "status": "interrupted",
                    "signal": interruption.signum,
                    "finishedAt": time.time(),
                    "failures": [str(interruption)],
                }
                write_step_state(output_dir, campaign, interrupted, keep_history=True)
                print(f"INTERRUPTED {phase_id}/{step['id']}", file=sys.stderr)
        campaign["status"] = "interrupted"
        campaign["finishedAt"] = time.time()
        campaign["interruptedBySignal"] = interruption.signum
        write_campaign_state(output_dir, campaign)
        print(f"INTERRUPTED receipt={output_dir / 'campaign.receipt.json'}", file=sys.stderr)
        return 128 + interruption.signum


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=None)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list", help="validate and list phases/steps")
    run_parser = subparsers.add_parser("run", help="run selected campaign phases")
    run_parser.add_argument("--phase", action="append", default=[])
    run_parser.add_argument("--step", action="append", default=[])
    run_parser.add_argument("--output-dir", type=Path)
    run_parser.add_argument("--allow-workspace-builds", action="store_true")
    run_parser.add_argument("--allow-subscription", action="store_true")
    run_parser.add_argument("--allow-live-control", action="store_true")
    run_parser.add_argument("--dry-run", action="store_true")
    run_parser.add_argument(
        "--resume", action="store_true",
        help="resume an exact prior invocation in --output-dir after re-verifying passed receipts")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    manifest_path = canonical(args.manifest or repo / "Tests/Fixtures/CapabilityCampaign/manifest.json")
    try:
        manifest = load_manifest(manifest_path)
    except Exception as error:
        print(f"manifest invalid: {error}", file=sys.stderr)
        return 2

    if args.command == "list":
        for phase in manifest["phases"]:
            print(f"{phase['id']}: {phase.get('description', '')}")
            for step in phase.get("steps", []):
                print(f"  {step['id']} [{step['safety']}] {step['kind']}")
        return 0

    if args.resume and args.output_dir is None:
        print("resume refused: --resume requires --output-dir", file=sys.stderr)
        return 2
    output_dir = canonical(args.output_dir) if args.output_dir else canonical(
        Path(tempfile.mkdtemp(prefix="kist-capability-")))
    if args.resume:
        if not output_dir.is_dir():
            print(f"resume refused: output directory does not exist: {output_dir}", file=sys.stderr)
            return 2
    else:
        output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        if any(output_dir.iterdir()):
            print("campaign refused: non-empty --output-dir requires --resume", file=sys.stderr)
            return 2
    os.chmod(output_dir, 0o700)
    runner_hash = sha256_file(Path(__file__).resolve())
    context = {
        "HOME": str(Path.home()), "TMP": str(output_dir), "KIST_REPO": str(repo),
        "RUNNER_SHA256": runner_hash,
    }
    for key, value in manifest.get("context", {}).items():
        context[key] = str(canonical(expand(str(value), context)))
    allowed_roots = [canonical(value) for value in context.values() if os.path.isabs(value)]

    selected_phases = set(args.phase or ["preflight"])
    selected_steps = set(args.step)
    unknown_phases = selected_phases - {phase["id"] for phase in manifest["phases"]}
    if unknown_phases:
        print(f"unknown phases: {sorted(unknown_phases)}", file=sys.stderr)
        return 2
    all_step_ids = {step["id"] for phase in manifest["phases"] for step in phase.get("steps", [])}
    unknown_steps = selected_steps - all_step_ids
    if unknown_steps:
        print(f"unknown steps: {sorted(unknown_steps)}", file=sys.stderr)
        return 2
    selected_phase_steps = {
        step["id"] for phase in manifest["phases"] if phase["id"] in selected_phases
        for step in phase.get("steps", [])
    }
    misplaced_steps = selected_steps - selected_phase_steps
    if misplaced_steps:
        print(f"selected steps are outside selected phases: {sorted(misplaced_steps)}", file=sys.stderr)
        return 2
    if not selected_phase_steps or (selected_steps and not (selected_steps & selected_phase_steps)):
        print("campaign selection contains no runnable steps", file=sys.stderr)
        return 2

    manifest_hash = sha256_file(manifest_path)
    invocation = invocation_contract(args, selected_phases, selected_steps)
    grants = vars(args)
    try:
        with CampaignRunLease(output_dir):
            if args.resume:
                campaign = load_json_object(
                    output_dir / "campaign.receipt.json", "campaign resume receipt")
                validate_resume_state(
                    campaign, manifest, manifest_path, manifest_hash,
                    output_dir, invocation, runner_hash)
            else:
                campaign = {
                    "runStateSchema": RUN_STATE_SCHEMA,
                    "schema": SCHEMA,
                    "manifest": str(manifest_path),
                    "manifestSHA256": manifest_hash,
                    "runnerSHA256": runner_hash,
                    "providerPolicy": manifest["providerPolicy"],
                    "invocation": invocation,
                    "startedAt": time.time(),
                    "outputDirectory": str(output_dir),
                    "status": "running",
                    "steps": [],
                }
            previous_handlers = install_signal_handlers()
            try:
                return run_selected_campaign(
                    manifest, manifest_path, manifest_hash, output_dir, context, allowed_roots,
                    selected_phases, selected_steps, grants, campaign, args.resume)
            finally:
                restore_signal_handlers(previous_handlers)
    except ResumeRefused as error:
        print(f"resume refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
