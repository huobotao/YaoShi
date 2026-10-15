#!/usr/bin/env python3
"""Make a private Watch import from a read-only Air R4 durable-state backup.

The output contains health records. Keep it outside the repository and never
put it in an app bundle. Copy only to the new Watch app's private Documents.
"""
import argparse
from datetime import datetime, timezone, timedelta
import hashlib
import json
import os
from pathlib import Path
import tempfile
import uuid

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True,
                        help="Read-only Air R4 Documents/durable-state.json backup")
    parser.add_argument("--manifest", type=Path, required=True,
                        help="Backup manifest.json with matching SHA-256 and capture time")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output.resolve()
    if output == source or source in output.parents:
        parser.error("Output must not overwrite or sit below the backup source")
    if ".git" in output.parts:
        parser.error("Output must not be inside a Git directory")
    manifest_path = args.manifest.resolve(strict=True)
    manifest = json.loads(manifest_path.read_bytes())
    try:
        relative = source.relative_to(manifest_path.parent).as_posix()
        entry = next(item for item in manifest["files"] if item["path"] == relative)
        captured = datetime.fromisoformat(manifest["createdAtUTC"].replace("Z", "+00:00"))
    except ValueError:
        parser.error("Source must belong to manifest and capture time must be valid")
    except (KeyError, StopIteration):
        parser.error("Source missing from backup manifest")
    if captured.tzinfo is None:
        parser.error("Manifest capture time must include a timezone")
    captured = captured.astimezone(timezone.utc)
    now = datetime.now(timezone.utc)
    if captured > now + timedelta(minutes=5):
        parser.error("Capture time is in the future")
    raw = source.read_bytes()
    if hashlib.sha256(raw).hexdigest() != entry.get("sha256") or len(raw) != entry.get("bytes"):
        parser.error("Backup SHA-256 or length does not match manifest")
    payload = json.loads(raw)
    settings = payload.get("settings") or {}
    peak = (settings.get("plasmaPeakTenthHoursOverride") or 38) / 10
    half = (settings.get("plasmaHalfLifeTenthHoursOverride") or 107) / 10
    if not (1 <= peak <= 12 and 1 <= half <= 48):
        parser.error("Curve parameters out of bounds")
    doses, seen = [], set()
    for item in payload.get("doses", []):
        dose_id = str(uuid.UUID(item["id"]))
        mg = item["mg"]
        food = item.get("food", "unknown")
        at = APPLE_EPOCH + timedelta(seconds=float(item["at"]))
        if dose_id in seen or not isinstance(mg, int) or not 5 <= mg <= 500 or mg % 5:
            parser.error("Invalid or duplicate dose")
        if item.get("med") != "Vyvanse" or food not in ("unknown", "withFood", "emptyStomach"):
            parser.error("Unsupported medication or food state")
        if not APPLE_EPOCH - timedelta(days=366) <= at <= captured + timedelta(minutes=5):
            parser.error("Dose outside validated time range")
        seen.add(dose_id)
        doses.append({"id": dose_id, "at": iso(at), "mg": mg, "food": food})
    if not doses or len(doses) > 10_000:
        parser.error("No doses or too many doses")
    out = {"schema": 1, "sourceCapturedAt": iso(captured), "exportedAt": iso(now),
           "sourceSHA256": hashlib.sha256(raw).hexdigest(), "peakHours": peak,
           "halfLifeHours": half, "doses": sorted(doses, key=lambda d: (d["at"], d["id"]))}
    encoded = json.dumps(out, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        parser.error("Output already exists; choose a new private path")
    fd, temporary = tempfile.mkstemp(prefix=".watch-import-", dir=output.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Created private Watch import: {len(doses)} doses, {len(encoded)} bytes, source SHA-256 {out['sourceSHA256']}")


if __name__ == "__main__":
    main()
