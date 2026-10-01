#!/usr/bin/env python3
"""Create a host-specific candidate bundle from a locally built Kist binary. Does not publish."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def package(binary, destination):
    binary = binary.resolve()
    if destination.exists():
        raise RuntimeError("Output directory already exists; choose a new directory.")
    version = subprocess.check_output([str(binary), "--version"], text=True, timeout=10).strip()
    resources = list(binary.parent.glob("*.bundle")) + list(binary.parent.glob("*.resources"))
    if not any(p.name.startswith("AgentCore_AgentCore.") for p in resources):
        raise RuntimeError("Built-in SwiftPM skills are missing beside the binary.")
    destination.mkdir(parents=True)
    try:
        (destination / "bin").mkdir()
        shutil.copy2(binary, destination / "bin/kist")
        for resource in resources:
            shutil.copytree(resource, destination / "bin" / resource.name)
        (destination / "runtime").mkdir()
        for name in ["runtime.py", "portable.py", "runtime_install.py"]:
            shutil.copy2(HERE / name, destination / "runtime" / name)
        shutil.copy2(HERE / "kist-launcher", destination / "kist")
        (destination / "kist").chmod(0o755)
        for name in ["install_bundle.py", "kist.ps1"]:
            shutil.copy2(HERE / name, destination / name)
        shutil.copy2(HERE / "DISTRIBUTION.md", destination / "README.md")
        files = {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in sorted(destination.rglob("*")) if p.is_file()}
        manifest = {"version": version, "target": sys.platform + "-" + platform.machine().lower(),
                    "status": "candidate-not-a-public-release", "files": files}
        (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(package(args.binary, args.output.resolve()), indent=2))
