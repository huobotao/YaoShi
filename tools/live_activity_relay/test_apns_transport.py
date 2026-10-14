"""Synthetic APNs wire-contract tests; no credentials or network are used."""
import base64
from contextlib import ExitStack
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from relay import APNsSender, TOPIC

NOW = 1800000000
COCOA_EPOCH_OFFSET = 978307200


def decode_segment(segment):
    return base64.urlsafe_b64decode(segment + '=' * (-len(segment) % 4))


class APNsTransportTests(unittest.TestCase):
    def setUp(self):
        self.contexts = ExitStack()
        self.addCleanup(self.contexts.close)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.path = Path(self.directory.name) / 'synthetic.p8'
        self.write_key(self.key)
        self.config = dict(apnsKeyPath=str(self.path), apnsKeyID='TESTKEY123',
                           apnsTeamID='TESTTEAM12', environment='sandbox')
        # Replace the entire HTTP client constructor before APNsSender runs.
        # These tests never instantiate a real network transport (or require h2).
        self.client_class = self.contexts.enter_context(patch('httpx.Client'))
        self.client = self.client_class.return_value
        self.response = Mock(status_code=200)
        self.response.json.side_effect = ValueError('Empty APNs success body')
        self.client.post.return_value = self.response
        self.clock = self.contexts.enter_context(patch('relay.time.time', return_value=NOW))

    def write_key(self, key):
        pem = key.private_bytes(serialization.Encoding.PEM,
                                serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'wb') as file:
            file.write(pem)
        self.assertEqual(0o600, self.path.stat().st_mode & 0o777)

    def verify_jwt(self, token, issued_at):
        encoded_header, encoded_claims, encoded_signature = token.split('.')
        self.assertEqual({'alg': 'ES256', 'kid': 'TESTKEY123'},
                         json.loads(decode_segment(encoded_header)))
        # APNs provider tokens use iss/iat, not an OAuth aud claim.
        self.assertEqual({'iss': 'TESTTEAM12', 'iat': issued_at},
                         json.loads(decode_segment(encoded_claims)))
        signature = decode_segment(encoded_signature)
        self.assertEqual(64, len(signature), 'JWT ES256 is raw r||s, not ASN.1 DER')
        r = int.from_bytes(signature[:32], 'big')
        s = int.from_bytes(signature[32:], 'big')
        self.key.public_key().verify(
            encode_dss_signature(r, s),
            (encoded_header + '.' + encoded_claims).encode(),
            ec.ECDSA(hashes.SHA256()))
        self.assertNotIn('=', token)

    def test_jwt_is_cryptographically_valid_es256_provider_token(self):
        sender = APNsSender(self.config)
        self.verify_jwt(sender.authorization(), NOW)
        self.client.post.assert_not_called()

    def test_jwt_reused_then_rotated_at_cache_boundary(self):
        sender = APNsSender(self.config)
        original = sender.authorization()
        self.clock.return_value = NOW + 2399
        self.assertEqual(original, sender.authorization())
        self.clock.return_value = NOW + 2400
        replacement = sender.authorization()
        self.assertNotEqual(original, replacement)
        self.verify_jwt(replacement, NOW + 2400)
        self.client.post.assert_not_called()

    def test_sandbox_and_production_select_http2_tls_endpoints(self):
        for environment, host in (
            ('sandbox', 'api.sandbox.push.apple.com'),
            ('production', 'api.push.apple.com'),
        ):
            with self.subTest(environment=environment):
                APNsSender(dict(self.config, environment=environment))
                self.client_class.assert_called_with(
                    http2=True, base_url='https://' + host, timeout=15)
        self.client.post.assert_not_called()

    def test_update_wire_contract_preserves_cocoa_state_and_unix_envelope(self):
        sender = APNsSender(self.config)
        cocoa_now = NOW - COCOA_EPOCH_OFFSET
        state = dict(lastDoseAt=cocoa_now-3600, lastMg=0, phaseRaw='none',
                     level=0.123, remainingRaw=None, plasmaSlopePerHour=-0.01,
                     peakEndAt=None, effectEndAt=cocoa_now+7200,
                     takenToday=0, targetAt=None, skippedToday=False, pillsLeft=0,
                     concentrationRatio=1.234, predictedPeakAt=None,
                     refreshedAt=cocoa_now)
        entry = dict(at=NOW, staleAt=NOW+120, contentState=state)
        token = 'ab' * 32
        self.assertEqual((200, ''), sender(token, entry))
        self.client.post.assert_called_once()
        args, kwargs = self.client.post.call_args
        self.assertEqual(('/3/device/' + token,), args)
        headers = kwargs['headers']
        self.assertEqual({
            'authorization', 'apns-topic', 'apns-push-type',
            'apns-priority', 'apns-expiration',
        }, set(headers))
        self.assertEqual(TOPIC, headers['apns-topic'])
        self.assertEqual('com.richardhuo.yaoshi.push-type.liveactivity', TOPIC)
        self.assertEqual('liveactivity', headers['apns-push-type'])
        self.assertEqual('5', headers['apns-priority'])
        self.assertEqual(str(NOW+120), headers['apns-expiration'])
        self.assertTrue(headers['authorization'].startswith('bearer '))
        self.verify_jwt(headers['authorization'].removeprefix('bearer '), NOW)
        payload = json.loads(kwargs['content'])
        self.assertEqual({'aps': {
            'timestamp': NOW, 'event': 'update',
            'content-state': state, 'stale-date': NOW+120,
        }}, payload)
        self.assertNotIn('alert', payload['aps'])
        self.assertNotIn('sound', payload['aps'])
        self.assertEqual(cocoa_now, payload['aps']['content-state']['refreshedAt'])
        self.assertLessEqual(len(kwargs['content']), 4096)
        # Transport must not mutate future schedule entries or state in place.
        self.assertEqual(cocoa_now, entry['contentState']['refreshedAt'])

    def test_apns_error_reason_is_returned_for_relay_token_invalidation(self):
        self.response.status_code = 410
        self.response.json.side_effect = None
        self.response.json.return_value = {'reason': 'Unregistered', 'timestamp': NOW}
        sender = APNsSender(self.config)
        self.assertEqual((410, 'Unregistered'), sender('ab'*32, {
            'at': NOW, 'staleAt': NOW+120, 'contentState': {},
        }))

    def test_non_json_error_body_does_not_hide_status(self):
        self.response.status_code = 503
        self.assertEqual((503, ''), APNsSender(self.config)('ab'*32, {
            'at': NOW, 'staleAt': NOW+120, 'contentState': {},
        }))

    def test_insecure_key_permissions_rejected_before_http_client_created(self):
        self.path.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'mode 600'):
            APNsSender(self.config)
        self.client_class.assert_not_called()

    def test_wrong_ec_curve_rejected_before_http_client_created(self):
        self.write_key(ec.generate_private_key(ec.SECP384R1()))
        with self.assertRaisesRegex(ValueError, 'P-256'):
            APNsSender(self.config)
        self.client_class.assert_not_called()


if __name__ == '__main__':
    unittest.main()
