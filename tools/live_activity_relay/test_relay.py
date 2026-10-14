import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
import threading
import http.client
from http.server import ThreadingHTTPServer
from relay import Relay, validate, handler_for

NOW = 1800000000

def registration(generation=1, token='ab' * 32):
    state = dict(lastMg=0, phaseRaw='none', level=0.1, takenToday=0, skippedToday=False,
                 pillsLeft=0, refreshedAt=NOW - 978307200, concentrationRatio=0.1)
    return dict(generation=generation, token=token, environment='sandbox', expiresAt=NOW+120,
                schedule=[dict(at=NOW+i, staleAt=NOW+i+60, contentState=state) for i in (0, 30, 60)])


class Tests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / 'state.json'
        self.now = NOW
        self.sent = []
        self.result = (200, '')
        def send(token, entry):
            self.sent.append((token, entry))
            return self.result
        self.relay = Relay(self.path, send, clock=lambda: self.now)

    def tearDown(self):
        self.directory.cleanup()

    def test_due_and_restart_never_repeats(self):
        self.assertEqual(200, self.relay.mutate('phone', 'activity', registration()))
        self.relay.tick()
        self.relay.tick()
        self.assertEqual(1, len(self.sent))
        restarted = Relay(self.path, self.relay.sender, clock=lambda: self.now)
        restarted.tick()
        self.assertEqual(1, len(self.sent))
        self.assertEqual(0o600, self.path.stat().st_mode & 0o777)

    def test_sleep_skips_backlog_and_expiry_removes_token(self):
        self.relay.mutate('phone', 'activity', registration())
        self.now += 65
        self.relay.tick()
        self.assertEqual(NOW+60, self.sent[0][1]['at'])
        self.now += 100
        self.relay.tick()
        self.assertEqual(1, len(self.sent))
        self.assertNotIn('abab', self.path.read_text())

    def test_generation_retries_rotation_withdrawal(self):
        one = registration()
        self.assertEqual(200, self.relay.mutate('p', 'a', one))
        self.assertEqual(200, self.relay.mutate('p', 'a', one))
        self.assertEqual(409, self.relay.mutate('p', 'a', registration(token='cd'*32)))
        self.assertEqual(200, self.relay.mutate('p', 'a', registration(2, 'cd'*32)))
        self.relay.tick()
        self.assertEqual('cd'*32, self.sent[0][0])
        self.assertEqual(200, self.relay.mutate('p', 'a', {'generation': 3}, True))
        self.assertEqual(409, self.relay.mutate('p', 'a', registration(2)))
        self.now += 30
        self.relay.tick()
        self.assertEqual(1, len(self.sent))

    def test_temporary_failure_retries_latest(self):
        self.result = (429, 'TooManyRequests')
        self.relay.mutate('p', 'a', registration())
        self.relay.tick()
        self.relay.tick()
        self.assertEqual(1, len(self.sent))
        self.result = (200, '')
        self.now += 35
        self.relay.tick()
        self.assertEqual(NOW+30, self.sent[-1][1]['at'])

    def test_invalid_token_forgets_private_payload(self):
        self.result = (410, 'Unregistered')
        self.relay.mutate('p', 'a', registration())
        self.relay.tick()
        self.now += 30
        self.relay.tick()
        self.assertEqual(1, len(self.sent))
        self.assertNotIn('abab', self.path.read_text())

    def test_device_isolation(self):
        self.relay.mutate('p', 'a', registration(100))
        self.assertEqual(200, self.relay.mutate('q', 'a', registration(1)))
        self.relay.tick()
        self.assertEqual(2, len(self.sent))

    def test_invalid_inputs(self):
        variants = []
        for key, value in [('generation', True), ('expiresAt', NOW+40000), ('token', 'invalid'),
                           ('topic', 'other'), ('environment', 'production'), ('rawDoses', [])]:
            body = registration()
            body[key] = value
            variants.append(body)
        for key, value in [('rawDoses', []), ('level', float('nan')), ('phaseRaw', 'x'*41),
                           ('lastMg', None), ('takenToday', 1.5), ('refreshedAt', None)]:
            body = registration()
            body['schedule'][0]['contentState'][key] = value
            variants.append(body)
        body = registration()
        body['schedule'].reverse()
        variants.append(body)
        body = registration()
        body['schedule'][0]['rawDoses'] = []
        variants.append(body)
        for body in variants:
            with self.subTest(body=body), self.assertRaises(ValueError):
                validate(body, NOW, 'sandbox')

    def test_http_authentication_and_device_scope(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), handler_for(self.relay, {'a': 'a'*32, 'b': 'b'*32}))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for secret, method, payload, expected in [
                ('wrong', 'PUT', registration(), 401),
                ('a'*32, 'PUT', registration(), 200),
                ('b'*32, 'DELETE', {'generation': 2}, 200),
                ('a'*32, 'PUT', registration(0), 409),
            ]:
                connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)
                connection.request(method, '/v1/activities/test', json.dumps(payload), {'Authorization': 'Bearer '+secret})
                response = connection.getresponse()
                self.assertEqual(expected, response.status)
                response.read()
                connection.close()
            self.relay.tick()
            self.assertEqual(1, len(self.sent))  # Device b cannot withdraw device a.
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    unittest.main()
