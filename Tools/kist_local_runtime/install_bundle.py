#!/usr/bin/env python3
"""Install an unpacked Kist bundle for the current user; never overwrite another installation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys


def install(bundle, prefix):
    manifest = json.loads((bundle / "manifest.json").read_text())
    target = sys.platform + "-" + platform.machine().lower()
    if manifest["target"] != target:
        raise RuntimeError(f"This bundle targets {manifest['target']}; this computer needs {target}.")
    # Checksums detect incomplete/corrupt transfers; they are not a publisher signature.
    actual = {str(p.relative_to(bundle)) for p in bundle.rglob("*")
              if p.is_file() and p.relative_to(bundle) != Path("manifest.json")}
    if actual != set(manifest["files"]) or any(p.is_symlink() for p in bundle.rglob("*")):
        raise RuntimeError("Bundle contains missing, extra or linked files.")
    for relative, digest in manifest["files"].items():
        path = bundle / relative
        if Path(relative).is_absolute() or ".." in Path(relative).parts or path.is_symlink():
            raise RuntimeError("Unsafe bundle path.")
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError("Bundle checksum mismatch: " + relative)
    destination = prefix / "share/kist/app"
    command = prefix / "bin/kist"
    if destination.exists() or command.exists() or command.is_symlink():
        raise RuntimeError("Kist is already installed at this prefix. Choose a new --prefix; no files were replaced.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    command.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copytree(bundle, destination, symlinks=False)
        (destination / "kist").chmod(0o755)
        (destination / "bin/kist").chmod(0o755)
        command.symlink_to(destination / "kist")
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    print(f"Installed. Open a terminal in your repo and run {command}")
    print(f"Add {command.parent} to PATH to use the short command: kist")
    return command


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local")
    args = parser.parse_args()
    try:
        install(Path(__file__).resolve().parent, args.prefix.expanduser().resolve())
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print("Kist installation: " + str(error), file=sys.stderr)
        raise SystemExit(2)
