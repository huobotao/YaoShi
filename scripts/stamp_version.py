#!/usr/bin/env python3
"""Stamp all bundles from one version file; reject mixed-source extensions."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def identity(component="app"):
    version = json.loads((ROOT / "version.json").read_text())[component]
    try:
        revision = subprocess.check_output(
            ["git", "rev-parse", "--short=12", "HEAD"], cwd=ROOT,
            stderr=subprocess.DEVNULL, text=True).strip()
        dirty = bool(subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            cwd=ROOT, text=True).strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        revision, dirty = "unversioned", True
    digest = hashlib.sha256()
    paths = [ROOT / "version.json", *ROOT.glob("build*.sh")]
    for directory in ("Sources", "Widget", "Watch", "NotificationService", "Shared", "icon", "scripts"):
        paths.extend(p for p in (ROOT / directory).rglob("*")
                     if p.is_file() and p.name != ".DS_Store"
                     and "__pycache__" not in p.parts and p.suffix != ".pyc")
    for path in sorted(paths):
        digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0")
        digest.update(path.read_bytes() + b"\0")
    return {
        "CFBundleShortVersionString": str(version["version"]),
        "CFBundleVersion": str(version["build"]),
        "YaoShiSourceRevision": revision,
        "YaoShiSourceDirty": dirty,
        "YaoShiSourceFingerprint": digest.hexdigest(),
    }


def stamp(path, component="app", parent=None):
    metadata = identity(component)
    if parent:
        parent_info = plistlib.loads(Path(parent).read_bytes())
        mismatched = [key for key, value in metadata.items() if parent_info.get(key) != value]
        if mismatched:
            raise SystemExit("主 App 与当前源码/版本不一致，请在新的构建目录重建主 App：" + ", ".join(mismatched))
    target = Path(path)
    info = plistlib.loads(target.read_bytes())
    info.update(metadata)
    target.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    print(f"版本 {metadata['CFBundleShortVersionString']} ({metadata['CFBundleVersion']}) · "
          f"{metadata['YaoShiSourceRevision']}" + (" · 未提交修改" if metadata['YaoShiSourceDirty'] else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist")
    parser.add_argument("--component", choices=("app", "partner"), default="app")
    parser.add_argument("--parent")
    arguments = parser.parse_args()
    stamp(arguments.plist, arguments.component, arguments.parent)
