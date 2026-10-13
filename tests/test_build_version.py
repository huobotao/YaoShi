"""Reproducibility checks run in disposable repositories, never the working tree."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "stamp_version", Path(__file__).resolve().parents[1] / "scripts/stamp_version.py")
STAMP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAMP)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="yaoshi-version-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source"
        self.root.mkdir()
        (self.root / "Sources").mkdir()
        (self.root / "Sources/App.swift").write_text("let value = 1\n")
        (self.root / "version.json").write_text(json.dumps({
            "app": {"version": "2.6", "build": "23"},
            "partner": {"version": "1.1", "build": "5"}}))
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-qm", "Fixture")
        root_patch = patch.object(STAMP, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()

    def plist(self, name):
        path = Path(self.temp.name) / name
        path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "fixture"}))
        return path

    def test_same_source_has_same_identity_after_relocation(self):
        original = STAMP.identity()
        moved = Path(self.temp.name) / "other-mac"
        shutil.copytree(self.root, moved)
        with patch.object(STAMP, "ROOT", moved):
            self.assertEqual(original, STAMP.identity())
        self.assertFalse(original["YaoShiSourceDirty"])
        self.assertEqual(original["YaoShiSourceRevision"], self.git("rev-parse", "--short=12", "HEAD"))

    def test_dirty_source_changes_fingerprint_even_with_same_commit(self):
        before = STAMP.identity()
        (self.root / "Sources/App.swift").write_text("let value = 2\n")
        after = STAMP.identity()
        self.assertEqual(before["YaoShiSourceRevision"], after["YaoShiSourceRevision"])
        self.assertTrue(after["YaoShiSourceDirty"])
        self.assertNotEqual(before["YaoShiSourceFingerprint"], after["YaoShiSourceFingerprint"])

    def test_extension_matches_parent_and_rejects_later_source_change(self):
        parent, extension = self.plist("app.plist"), self.plist("widget.plist")
        STAMP.stamp(parent)
        STAMP.stamp(extension, parent=parent)
        self.assertEqual(parent.read_bytes(), extension.read_bytes())
        info = plistlib.loads(parent.read_bytes())
        self.assertEqual((info["CFBundleShortVersionString"], info["CFBundleVersion"]), ("2.6", "23"))
        (self.root / "Sources/New.swift").write_text("let newValue = 3\n")
        previous_extension = extension.read_bytes()
        with self.assertRaises(SystemExit):
            STAMP.stamp(extension, parent=parent)
        self.assertEqual(previous_extension, extension.read_bytes())

    def test_archive_without_git_is_explicitly_unversioned(self):
        shutil.rmtree(self.root / ".git")
        identity = STAMP.identity()
        self.assertEqual(identity["YaoShiSourceRevision"], "unversioned")
        self.assertTrue(identity["YaoShiSourceDirty"])
        self.assertEqual(len(identity["YaoShiSourceFingerprint"]), 64)

    def test_partner_keeps_its_own_release_version(self):
        partner = STAMP.identity("partner")
        self.assertEqual((partner["CFBundleShortVersionString"], partner["CFBundleVersion"]), ("1.1", "5"))


if __name__ == "__main__":
    unittest.main()
