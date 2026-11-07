#!/usr/bin/env python3
"""Stock API compatibility smoke test, restricted to the disposable local lab."""
import datetime
import hashlib
import json
import os
import secrets
import struct
import subprocess
import urllib.error
import urllib.request
import zlib
from pathlib import Path
from lab import ROOT, STATE, command, require_local_engine

BASE = 'http://127.0.0.1:22840/api'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise RuntimeError('The local test endpoint must not redirect')


OPENER = urllib.request.build_opener(NoRedirect, urllib.request.ProxyHandler({}))


def request(method, path, payload=None, token=None, content_type=None):
    data = payload if isinstance(payload, bytes) else json.dumps(payload).encode() if payload is not None else None
    headers = {'Content-Type': content_type or 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    with OPENER.open(req, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body and 'json' in response.headers.get('Content-Type', '') else body


def login(account):
    return request('POST', '/auth/login', {k: account[k] for k in ('email', 'password')})['accessToken']


def png():
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    # A deterministic, synthetic 32x32 RGB fixture; no external media input.
    raw = b''.join(b'\x00' + bytes([20, 130, 220]) * 32 for _ in range(32))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 32, 32, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def upload(token):
    boundary = 'gallery' + secrets.token_hex(12)
    fields = {'deviceId': 'gallery-review-disposable-lab', 'deviceAssetId': 'pipeline-fixture-v1',
              'fileCreatedAt': '2026-01-01T12:00:00Z', 'fileModifiedAt': '2026-01-01T12:00:00Z'}
    parts = []
    for key, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="assetData"; filename="pipeline-synthetic.png"\r\nContent-Type: image/png\r\n\r\n'.encode() + png() + b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())
    return request('POST', '/assets', b''.join(parts), token, 'multipart/form-data; boundary=' + boundary)['id']


def main():
    require_local_engine()
    os.umask(0o077)
    STATE.mkdir(mode=0o700, exist_ok=True)
    (STATE / 'smoke.json').unlink(missing_ok=True)
    container = subprocess.check_output(command() + ['ps', '-q', 'immich-server'], text=True).strip()
    if not container:
        raise RuntimeError('Start the dedicated Compose lab first')
    info = json.loads(subprocess.check_output(['docker', 'inspect', container], text=True))[0]
    assert info['Config']['Labels']['com.docker.compose.project'] == 'gallery-review-lab'
    bindings = info['NetworkSettings']['Ports']['2283/tcp']
    assert bindings == [{'HostIp': '127.0.0.1', 'HostPort': '22840'}], 'Unexpected lab port binding'
    file = STATE / 'lab-accounts.json'
    if not file.exists():
        accounts = {name: {'email': f'{name}@gallery-lab.invalid', 'name': 'Synthetic ' + name,
                           'password': secrets.token_urlsafe(24)} for name in ('admin', 'reviewer', 'outsider')}
        request('POST', '/auth/admin-sign-up', accounts['admin'])
        # Persist immediately so a later failed provisioning step can be retried.
        file.write_text(json.dumps(accounts, indent=2) + '\n')
    accounts = json.loads(file.read_text())
    admin = login(accounts['admin'])
    for name in ('reviewer', 'outsider'):
        if 'id' not in accounts[name]:
            created = request('POST', '/admin/users', {**accounts[name], 'isAdmin': False,
                              'notify': False, 'shouldChangePassword': False, 'quotaSizeInBytes': 1073741824}, admin)
            accounts[name]['id'] = created['id']
            file.write_text(json.dumps(accounts, indent=2) + '\n')
    # This lab does not start ML: unrelated face/search jobs must not need another service.
    config = request('GET', '/system-config', token=admin)
    config['machineLearning']['enabled'] = False
    request('PUT', '/system-config', config, admin)
    reviewer = login(accounts['reviewer'])
    outsider = login(accounts['outsider'])
    me = request('GET', '/users/me', token=reviewer)
    assert not me['isAdmin'] and me['id'] == accounts['reviewer']['id']
    asset_id = upload(reviewer)
    asset = request('GET', '/assets/' + asset_id, token=reviewer)
    assert asset['ownerId'] == me['id'] and asset['originalFileName'] == 'pipeline-synthetic.png'
    # Test access denial before any trash mutation, using another synthetic user.
    for method, path, payload in [('GET', '/assets/' + asset_id, None),
                                  ('DELETE', '/assets', {'ids': [asset_id], 'force': False})]:
        try:
            request(method, path, payload, outsider)
        except urllib.error.HTTPError as error:
            assert error.code in (400, 403, 404), f'Unexpected denial status: {error.code}'
        else:
            raise AssertionError('Cross-account access was accepted')
    try:
        request('DELETE', '/assets', {'ids': [asset_id], 'force': False}, reviewer)
        assert request('GET', '/assets/' + asset_id, token=reviewer)['isTrashed']
    finally:
        request('POST', '/trash/restore/assets', {'ids': [asset_id]}, reviewer)
    assert not request('GET', '/assets/' + asset_id, token=reviewer)['isTrashed']
    restored = request('GET', '/assets/' + asset_id + '/original', token=reviewer)
    assert hashlib.sha256(restored).digest() == hashlib.sha256(png()).digest()
    assert upload(reviewer) == asset_id, 'Duplicate upload did not resolve to the existing asset'
    result = {'passed': True, 'image_id': info['Image'], 'version': request('GET', '/server/version'),
              'time_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'checks': ['non-admin login', 'synthetic upload', 'cross-account read/delete denial',
                         'recoverable trash', 'restore', 'original checksum', 'duplicate upload']}
    (STATE / 'smoke.json').write_text(json.dumps(result, indent=2) + '\n')
    print('PASS: ' + ', '.join(result['checks']))
    print('Local API checks do not establish physical-device deletion or restore.')


if __name__ == '__main__':
    main()
