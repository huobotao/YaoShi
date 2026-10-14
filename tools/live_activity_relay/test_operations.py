import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from operations import check_config, generate_launchd, status
from relay import Relay, atomic_save
from test_relay import registration, NOW


class Tests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.config = self.root / 'config.json'
        self.state = self.root / 'state.json'
        self.body = {'environment': 'sandbox', 'deviceSecrets': {'test': 'a'*32},
                     'statePath': str(self.state), 'apnsKeyPath': 'missing',
                     'apnsKeyID': 'synthetic', 'apnsTeamID': 'synthetic'}
        atomic_save(self.config, self.body)

    def tearDown(self):
        self.directory.cleanup()

    def test_missing_key_fails_without_private_values(self):
        result = check_config(self.config)
        self.assertFalse(result['ready'])
        self.assertNotIn('a'*32, json.dumps(result))
        self.assertNotIn(str(self.config), json.dumps(result))

    def test_matching_client_and_plaintext_rejection(self):
        client = self.root / 'client.json'
        atomic_save(client, {'endpoint': 'https://relay.example.test', 'authorizationToken': 'a'*32, 'environment': 'sandbox'})
        with patch('operations.APNsSender'), patch('operations.importlib.util.find_spec', return_value=True):
            self.assertTrue(check_config(self.config, client)['ready'])
            self.body['bindHost'] = '0.0.0.0'
            atomic_save(self.config, self.body)
            result = check_config(self.config, client)
            self.assertFalse(result['ready'])
            self.assertEqual([{'check': 'listenerTLS', 'ok': False}], [c for c in result['checks'] if not c['ok']])

    def test_generation_only_launchd_no_secrets(self):
        output = self.root / 'relay.plist'
        with patch('operations.APNsSender'), patch('operations.importlib.util.find_spec', return_value=True):
            result = generate_launchd(self.config, output)
        self.assertFalse(result['started'])
        self.assertFalse(result['installed'])
        data = plistlib.loads(output.read_bytes())
        self.assertEqual('/dev/null', data['StandardErrorPath'])
        self.assertNotIn('a'*32, output.read_text())
        self.assertEqual(0o600, output.stat().st_mode & 0o777)
        with patch('operations.APNsSender'), patch('operations.importlib.util.find_spec', return_value=True), self.assertRaises(ValueError):
            generate_launchd(self.config, self.root / 'LaunchAgents' / 'relay.plist')

    def test_operational_status_contains_no_payload(self):
        status_path = str(self.state) + '.status.json'
        relay = Relay(self.state, lambda *_: (200, ''), clock=lambda: NOW, status_path=status_path)
        relay.mutate('synthetic-device', 'synthetic-activity', registration())
        relay.tick()
        result = status(self.config, now=NOW)
        self.assertTrue(result['running'])
        self.assertEqual(NOW, result['lastAPNsAcceptedAt'])
        self.assertEqual(1, result['acceptedCount'])
        text = json.dumps(result)
        self.assertNotIn('abab', text)
        self.assertNotIn('concentration', text)
        self.assertNotIn('synthetic-device', text)
        self.assertFalse(status(self.config, now=NOW+91)['running'])

    def test_private_configuration_required(self):
        self.config.chmod(0o644)
        self.assertFalse(check_config(self.config)['ready'])


if __name__ == '__main__':
    unittest.main()
