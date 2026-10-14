import importlib.util
from pathlib import Path
from datetime import datetime, timedelta
import unittest

spec = importlib.util.spec_from_file_location("select_profile", Path(__file__).resolve().parents[1] / "scripts/select_profile.py")
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class SigningProfileTests(unittest.TestCase):
    app = "TESTTEAM.com.example.app"

    def profile(self, identifier, push=None, days=1):
        entitlements = {"application-identifier": identifier}
        if push is not None:
            entitlements["aps-environment"] = push
        return {"Entitlements": entitlements, "ExpirationDate": datetime.utcnow() + timedelta(days=days)}

    def test_legacy_wildcard_allowed_only_for_nonpush_builds(self):
        value = self.profile("TESTTEAM.*")
        self.assertTrue(selector.usable(value, self.app))
        self.assertFalse(selector.usable(value, self.app, True))

    def test_explicit_push_profile_required(self):
        self.assertTrue(selector.usable(self.profile(self.app, "development"), self.app, True))
        self.assertTrue(selector.usable(self.profile(self.app, "production"), self.app, True))
        self.assertFalse(selector.usable(self.profile(self.app), self.app, True))
        self.assertFalse(selector.usable(self.profile(self.app, "invalid"), self.app, True))

    def test_expired_wrong_team_and_widget_profile_rejected(self):
        self.assertFalse(selector.usable(self.profile(self.app, days=-1), self.app))
        self.assertFalse(selector.usable(self.profile("OTHERTEAM.*"), self.app))
        self.assertFalse(selector.usable(self.profile(self.app + ".widget"), self.app))
        self.assertFalse(selector.usable(self.profile(self.app), self.app + ".widget"))


if __name__ == "__main__":
    unittest.main()
