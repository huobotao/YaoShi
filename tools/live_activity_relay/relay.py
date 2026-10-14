#!/usr/bin/env python3
"""Private, opt-in local ActivityKit relay. Never logs payloads or identifiers."""
import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import ssl
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOPIC = 'com.richardhuo.yaoshi.push-type.liveactivity'
FIELDS = set('lastDoseAt lastMg phaseRaw level remainingRaw plasmaSlopePerHour peakEndAt effectEndAt takenToday targetAt skippedToday pillsLeft concentrationRatio predictedPeakAt refreshedAt'.split())
REQUIRED = set('lastMg phaseRaw level takenToday skippedToday pillsLeft refreshedAt'.split())


def dumps(value):
    return json.dumps(value, separators=(',', ':'), allow_nan=False).encode()


def private_read(path):
    path = Path(path)
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise ValueError('Private file must not be a symlink and must have mode 600')
    return path.read_bytes()


def atomic_save(path, value):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.relay-')
    try:
        with os.fdopen(fd, 'wb') as file:
            file.write(dumps(value))
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def validate(body, now, environment):
    if not isinstance(body, dict) or not integer(body.get('generation')) or not 0 <= body['generation'] < 2**63:
        raise ValueError('Invalid generation')
    if body.keys() - {'generation', 'token', 'topic', 'environment', 'expiresAt', 'schedule'}:
        raise ValueError('Unexpected registration fields')
    if body.get('topic', TOPIC) != TOPIC or body.get('environment', environment) != environment:
        raise ValueError('Topic or environment mismatch')
    if not isinstance(body.get('token'), str) or not re.fullmatch(r'[0-9a-fA-F]{32,1024}', body['token']) or len(body['token']) % 2:
        raise ValueError('Invalid token')
    expiry = body.get('expiresAt')
    if not integer(expiry) or not now < expiry <= now + 8 * 3600 + 60:
        raise ValueError('Invalid expiry')
    schedule = body.get('schedule')
    if not isinstance(schedule, list) or not 1 <= len(schedule) <= 961:
        raise ValueError('Invalid schedule')
    previous = 0
    for entry in schedule:
        if not isinstance(entry, dict):
            raise ValueError('Invalid entry')
        if entry.keys() != {'at', 'staleAt', 'contentState'}:
            raise ValueError('Unexpected entry fields')
        at, stale = entry.get('at'), entry.get('staleAt')
        if not integer(at) or not integer(stale) or not now - 300 <= at < expiry or not at < stale <= expiry + 120 or at <= previous:
            raise ValueError('Invalid schedule dates')
        previous = at
        state = entry.get('contentState')
        if not isinstance(state, dict) or not REQUIRED <= state.keys() or state.keys() - FIELDS:
            raise ValueError('Invalid display state fields')
        for key, value in state.items():
            if key in {'lastMg', 'takenToday', 'pillsLeft'}:
                if not integer(value) or not -(2**63) <= value < 2**63:
                    raise ValueError('Invalid integer display value')
            elif key in {'level', 'refreshedAt'}:
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                    raise ValueError('Invalid required display value')
            elif key == 'phaseRaw':
                if not isinstance(value, str) or len(value) > 40:
                    raise ValueError('Invalid phase')
            elif key == 'skippedToday':
                if not isinstance(value, bool):
                    raise ValueError('Invalid flag')
            elif value is not None and (isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)):
                raise ValueError('Invalid display value')
        if len(dumps({'aps': {'timestamp': at, 'event': 'update', 'content-state': state, 'stale-date': stale}})) > 4096:
            raise ValueError('Display payload too large')
    return body


class APNsSender:
    def __init__(self, config):
        import httpx
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
        from cryptography.hazmat.primitives.asymmetric import ec
        self.key = load_pem_private_key(private_read(config['apnsKeyPath']), password=None)
        if not isinstance(self.key, ec.EllipticCurvePrivateKey) or not isinstance(self.key.curve, ec.SECP256R1):
            raise ValueError('APNs requires a P-256 key')
        self.key_id, self.team_id = config['apnsKeyID'], config['apnsTeamID']
        host = 'api.sandbox.push.apple.com' if config['environment'] == 'sandbox' else 'api.push.apple.com'
        self.client = httpx.Client(http2=True, base_url='https://' + host, timeout=15)
        self.jwt, self.jwt_at = '', 0

    def authorization(self):
        now = int(time.time())
        if now - self.jwt_at < 2400:
            return self.jwt
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
        from cryptography.hazmat.primitives import hashes
        enc = lambda value: base64.urlsafe_b64encode(value).rstrip(b'=')
        unsigned = enc(dumps({'alg': 'ES256', 'kid': self.key_id})) + b'.' + enc(dumps({'iss': self.team_id, 'iat': now}))
        r, s = decode_dss_signature(self.key.sign(unsigned, ec.ECDSA(hashes.SHA256())))
        self.jwt = (unsigned + b'.' + enc(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))).decode()
        self.jwt_at = now
        return self.jwt

    def __call__(self, token, entry):
        response = self.client.post('/3/device/' + token, headers={
            'authorization': 'bearer ' + self.authorization(), 'apns-topic': TOPIC,
            'apns-push-type': 'liveactivity', 'apns-priority': '5',
            'apns-expiration': str(entry['staleAt']),
        }, content=dumps({'aps': {'timestamp': entry['at'], 'event': 'update',
                                 'content-state': entry['contentState'], 'stale-date': entry['staleAt']}}))
        reason = ''
        try:
            reason = response.json().get('reason', '')
        except (ValueError, AttributeError):
            pass
        return response.status_code, reason


class Relay:
    def __init__(self, path, sender, environment='sandbox', clock=time.time, status_path=None):
        self.path, self.sender, self.environment, self.clock = Path(path), sender, environment, clock
        self.lock = threading.RLock()
        self.records = json.loads(private_read(path)) if self.path.exists() else {}
        self.status_path = Path(status_path) if status_path else None
        self.status = {'pid': os.getpid(), 'startedAt': int(clock()), 'heartbeatAt': 0,
                       'acceptedCount': 0, 'failedCount': 0, 'lastAPNsAcceptedAt': None,
                       'lastAPNsHTTPStatus': None, 'storageErrors': 0}

    def write_status(self):
        if self.status_path:
            self.status['heartbeatAt'] = int(self.clock())
            atomic_save(self.status_path, self.status)

    def mutate(self, device, activity, body, withdraw=False):
        now = int(self.clock())
        if not isinstance(body, dict) or not integer(body.get('generation')) or not 0 <= body['generation'] < 2**63:
            raise ValueError('Invalid generation')
        if withdraw and body.keys() != {'generation'}:
            raise ValueError('Unexpected withdrawal fields')
        if not withdraw:
            validate(body, now, self.environment)
        digest = hashlib.sha256(dumps(body)).hexdigest()
        key = device + ':' + activity
        with self.lock:
            old = self.records.get(key)
            if old and body['generation'] <= old['generation']:
                return 200 if old['generation'] == body['generation'] and old['digest'] == digest and old['withdrawn'] == withdraw else 409
            self.records[key] = {'generation': body['generation'], 'digest': digest, 'withdrawn': withdraw,
                                 'body': None if withdraw else body, 'lastSent': 0, 'retryAt': 0, 'failures': 0,
                                 'retainUntil': now + 86400}
            atomic_save(self.path, self.records)
        return 200

    def tick(self):
        # Serialize registration with sends so an obsolete generation is never sent after its replacement.
        with self.lock:
            now = int(self.clock())
            changed = False
            for key, record in list(self.records.items()):
                if record['retainUntil'] < now:
                    del self.records[key]
                    changed = True
                    continue
                body = record['body']
                if record['withdrawn'] or body is None:
                    continue
                if body['expiresAt'] <= now:
                    record['body'] = None
                    changed = True
                    continue
                if record['retryAt'] > now:
                    continue
                due = [e for e in body['schedule'] if record['lastSent'] < e['at'] <= now and e['staleAt'] > now]
                if not due:
                    continue
                entry = due[-1]  # Never replay a backlog after sleep/network loss.
                try:
                    status, reason = self.sender(body['token'], entry)
                except Exception:
                    status, reason = 503, ''  # Deliberately never log exception URLs/tokens.
                self.status['lastAPNsHTTPStatus'] = status
                if status == 200:
                    self.status['acceptedCount'] += 1
                    self.status['lastAPNsAcceptedAt'] = now
                else:
                    self.status['failedCount'] += 1
                if status == 200:
                    record['lastSent'], record['failures'], record['retryAt'] = entry['at'], 0, 0
                elif status == 410 or reason in ('BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'):
                    record['body'] = None  # Require token rotation/new generation.
                else:
                    record['failures'] += 1
                    record['retryAt'] = now + min(300, 5 * 2 ** min(record['failures'], 6))
                changed = True
            if changed:
                atomic_save(self.path, self.records)
            if changed or now - self.status['heartbeatAt'] >= 30:
                self.write_status()


def handler_for(relay, secrets):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def handle_mutation(self, withdraw):
            self.connection.settimeout(10)
            auth = self.headers.get('Authorization', '')
            device = next((alias for alias, secret in secrets.items() if hmac.compare_digest(auth.encode(), ('Bearer ' + secret).encode())), None)
            if device is None:
                self.send_error(401)
                return
            match = re.fullmatch(r'/v1/activities/([A-Za-z0-9_-]{1,128})', self.path)
            if not match:
                self.send_error(404)
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 2_000_000 or self.headers.get('Transfer-Encoding'):
                    raise ValueError('Invalid request size')
                body = json.loads(self.rfile.read(length))
                status = relay.mutate(device, match[1], body, withdraw)
            except (ValueError, TypeError, KeyError, OverflowError):
                status = 400
            except Exception:
                status = 503
            response = dumps({'ok': status == 200})
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        def do_PUT(self):
            self.handle_mutation(False)

        def do_DELETE(self):
            self.handle_mutation(True)
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True, help='Private mode-600 JSON config path outside repository')
    args = parser.parse_args()
    config = json.loads(private_read(args.config))
    if config['environment'] not in ('sandbox', 'production'):
        raise ValueError('Explicit sandbox or production environment required')
    secrets = config['deviceSecrets']
    if not isinstance(secrets, dict) or not secrets or any(not isinstance(v, str) or len(v) < 32 for v in secrets.values()) or len(set(secrets.values())) != len(secrets):
        raise ValueError('Distinct high-entropy per-device secrets required')
    host = config.get('bindHost', '127.0.0.1')
    cert, key = config.get('tlsCertPath'), config.get('tlsKeyPath')
    if not (cert and key) and host not in ('127.0.0.1', '::1', 'localhost'):
        raise ValueError('Non-loopback binding requires TLS')
    storage = Path(config['statePath']).expanduser()
    storage.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # A second process must not race writes or emit duplicate/out-of-order pushes.
    lock_fd = os.open(str(storage) + '.lock', os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    relay = Relay(storage, APNsSender(config), config['environment'],
                  status_path=config.get('statusPath', str(storage) + '.status.json'))
    server = ThreadingHTTPServer((host, config.get('port', 8443)), handler_for(relay, secrets))
    if cert and key:
        private_read(key)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    def worker():
        while True:
            try:
                relay.tick()
            except Exception:
                relay.status['storageErrors'] += 1
                try:
                    relay.write_status()
                except Exception:
                    pass  # Keep serving without leaking private state via traceback.
            time.sleep(1)
    threading.Thread(target=worker, daemon=True).start()
    print('Live Activity relay running; private payload logging disabled.', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
