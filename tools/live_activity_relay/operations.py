#!/usr/bin/env python3
"""Read-only readiness/status checks and generation-only launchd configuration."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import ssl
import sys
import time
from urllib.parse import urlparse
from relay import private_read, APNsSender


def check_config(path, client_path=None):
    checks = []
    config = None
    def check(name, fn):
        try:
            fn()
            checks.append({'check': name, 'ok': True})
            return True
        except Exception:
            # Exception messages may contain filesystem paths, credentials or URLs.
            checks.append({'check': name, 'ok': False})
            return False
    def load():
        nonlocal config
        config = json.loads(private_read(path))
        if not isinstance(config, dict):
            raise ValueError()
    if not check('privateConfiguration', load):
        return {'ready': False, 'checks': checks}
    def dependencies():
        if any(importlib.util.find_spec(name) is None for name in ('httpx', 'h2', 'cryptography')):
            raise ValueError()
    check('http2Dependencies', dependencies)
    def environment():
        if config.get('environment') not in ('sandbox', 'production'):
            raise ValueError()
        if not isinstance(config.get('port', 8443), int) or not 1 <= config.get('port', 8443) <= 65535:
            raise ValueError()
    check('environmentAndPort', environment)
    def secrets():
        values = config.get('deviceSecrets', {})
        if not isinstance(values, dict) or not values or any(not isinstance(k, str) or not isinstance(v, str) or len(v) < 32 for k, v in values.items()) or len(values) != len(set(values.values())):
            raise ValueError()
    check('perDeviceSecrets', secrets)
    def key():
        if not all(isinstance(config.get(k), str) and config[k] for k in ('apnsKeyID', 'apnsTeamID', 'apnsKeyPath')):
            raise ValueError()
        sender = APNsSender(config)
        try:
            sender.authorization()  # Local ES256 signing only. No network request.
        finally:
            sender.client.close()
    check('privateAPNsSigningKey', key)
    def storage():
        paths = [config['statePath'], config.get('statusPath', config['statePath'] + '.status.json')]
        if paths[0] == paths[1]:
            raise ValueError()
        for name in paths:
            target = Path(name)
            if not target.is_absolute() or target.is_symlink():
                raise ValueError()
            if target.exists():
                private_read(target)
            parent = target.parent
            while not parent.exists():
                parent = parent.parent
            if not os.access(parent, os.W_OK | os.X_OK):
                raise ValueError()
    check('privateWritableStorage', storage)
    def tls():
        cert, key = config.get('tlsCertPath'), config.get('tlsKeyPath')
        if cert and key:
            from cryptography import x509
            certificate = x509.load_pem_x509_certificate(Path(cert).read_bytes())
            now = datetime.now(timezone.utc)
            if not certificate.not_valid_before_utc <= now <= certificate.not_valid_after_utc:
                raise ValueError()
            private_read(key)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
        elif config.get('bindHost', '127.0.0.1') not in ('127.0.0.1', '::1', 'localhost'):
            raise ValueError()
        elif cert or key:
            raise ValueError()
    check('listenerTLS', tls)
    if client_path:
        def client():
            candidate = json.loads(private_read(client_path))
            url = urlparse(candidate['endpoint'])
            if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path.rstrip('/'):
                raise ValueError()
            if candidate['environment'] != config['environment'] or candidate['authorizationToken'] not in config['deviceSecrets'].values():
                raise ValueError()
        check('clientConfigurationMatch', client)
    return {'ready': all(item['ok'] for item in checks), 'checks': checks,
            'networkVerified': False, 'apnsDeliveryVerified': False,
            'note': 'Local readiness only. HTTPS trust, device signing entitlement and APNs delivery require separate verification.'}


def status(path, now=None):
    config = json.loads(private_read(path))
    state = json.loads(private_read(config.get('statusPath', config['statePath'] + '.status.json')))
    current = time.time() if now is None else now
    # Copy only known non-private operational fields, never arbitrary state contents.
    fields = ('pid', 'startedAt', 'heartbeatAt', 'acceptedCount', 'failedCount',
              'lastAPNsAcceptedAt', 'lastAPNsHTTPStatus', 'storageErrors')
    result = {key: state.get(key) if isinstance(state.get(key), (int, float)) and not isinstance(state.get(key), bool) else None for key in fields}
    try:
        pid = result['pid']
        if not isinstance(pid, int) or pid <= 0:
            raise ValueError()
        os.kill(pid, 0)
        result['pidExists'] = True
    except (ValueError, TypeError, ProcessLookupError, PermissionError):
        result['pidExists'] = False
    heartbeat = result['heartbeatAt']
    result['heartbeatFresh'] = isinstance(heartbeat, (int, float)) and 0 <= current-heartbeat <= 90
    result['running'] = result['pidExists'] and result['heartbeatFresh']
    result['deviceDeliveryVerified'] = False
    return result


def generate_launchd(config_path, output_path):
    report = check_config(config_path)
    if not report['ready']:
        raise ValueError('Configuration is not locally ready')
    output = Path(output_path)
    # Only generate an artifact; never write directly into system/user launchd folders.
    if 'LaunchAgents' in output.parts or 'LaunchDaemons' in output.parts:
        raise ValueError('Choose a staging path outside launchd directories')
    document = {'Label': 'com.richardhuo.yaoshi.live-activity-relay',
                'ProgramArguments': [str(Path(sys.executable).resolve()), str(Path(__file__).with_name('relay.py').resolve()),
                                     '--config', str(Path(config_path).resolve())],
                'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 30,
                'Umask': 0o077, 'StandardOutPath': '/dev/null', 'StandardErrorPath': '/dev/null'}
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as file:
        file.write(plistlib.dumps(document))
    return {'generated': True, 'installed': False, 'started': False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('check', 'status', 'launchd'))
    parser.add_argument('--config', required=True)
    parser.add_argument('--client-config')
    parser.add_argument('--output')
    args = parser.parse_args()
    try:
        if args.command == 'check':
            result = check_config(args.config, args.client_config)
        elif args.command == 'status':
            result = status(args.config)
        else:
            if not args.output:
                raise ValueError()
            result = generate_launchd(args.config, args.output)
    except Exception:
        result = {'ok': False, 'error': 'Local operation failed; inspect private files and permissions without publishing their contents.'}
    print(json.dumps(result, indent=2))
    if result.get('ready') is False or result.get('ok') is False:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
