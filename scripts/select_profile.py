#!/usr/bin/env python3
"""Select a compatible local signing profile without exposing private material."""
import argparse
from datetime import datetime, timezone
import fnmatch
from pathlib import Path
import plistlib
import subprocess


def usable(profile, app_id, require_push=False):
    ent = profile.get("Entitlements", {})
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime):
        return False
    if expiry.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        return False
    allowed = ent.get("application-identifier", "")
    if not fnmatch.fnmatchcase(app_id, allowed):
        return False
    if require_push and (allowed != app_id or ent.get("aps-environment") not in ("development", "production")):
        return False
    return True


def main():
    p = argparse.ArgumentParser()
    p.add_argument("app_id")
    p.add_argument("--require-push", action="store_true")
    p.add_argument("--profile", type=Path)
    args = p.parse_args()
    candidates = [args.profile] if args.profile else list(Path.home().joinpath(
        "Library/Developer/Xcode/UserData/Provisioning Profiles").glob("*.mobileprovision"))
    matches = []
    for path in candidates:
        result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
        if result.returncode:
            continue
        try:
            value = plistlib.loads(result.stdout)
        except Exception:
            continue
        if usable(value, args.app_id, args.require_push):
            exact = value["Entitlements"]["application-identifier"] == args.app_id
            matches.append((exact, value["ExpirationDate"], str(path)))
    if not matches:
        raise SystemExit("没有匹配的有效签名描述文件" + ("（必须包含 APNs 权限）" if args.require_push else ""))
    print(max(matches)[2])


if __name__ == "__main__":
    main()
