#!/usr/bin/env python3
"""Read-only post-deployment smoke using an explicitly scoped synthetic account."""
import json
import stat
import urllib.parse
import urllib.request
from pathlib import Path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise RuntimeError('Smoke endpoint redirects are not permitted')


def load_config(path):
    path = Path(path)
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ValueError('Synthetic account config must be owner-only (chmod 600)')
    config = json.loads(path.read_text())
    url = urllib.parse.urlsplit(config['api_url'])
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError('Expected a private HTTPS API URL without embedded credentials')
    for key in ('email', 'password', 'expected_user_id', 'expected_asset_names'):
        if not config.get(key):
            raise ValueError('Missing explicit synthetic account scope: ' + key)
    return config


def check(config, expected_version):
    opener = urllib.request.build_opener(NoRedirect, urllib.request.ProxyHandler({}))
    base = config['api_url'].rstrip('/')
    def request(path, token=None, body=None):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                     headers=headers)
        with opener.open(req, timeout=30) as response:
            return json.load(response)
    version = request('/server/version')
    assert '.'.join(str(version[k]) for k in ('major', 'minor', 'patch')) == expected_version
    login = request('/auth/login', body={k: config[k] for k in ('email', 'password')})
    token = login['accessToken']
    user = request('/users/me', token)
    assert user['id'] == config['expected_user_id'] and not user['isAdmin'], 'Wrong synthetic account'
    result = request('/search/metadata', token, {'withDeleted': True, 'size': 100})
    assets = result['assets']['items']
    assert result['assets'].get('nextPage') is None, 'Unexpected large test library'
    assert sorted(a['originalFileName'] for a in assets) == sorted(config['expected_asset_names'])
    assert all(a['ownerId'] == user['id'] for a in assets)
    print('PASS: expected server version, scoped non-admin login, exact synthetic asset inventory. No media mutated.')
