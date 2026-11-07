#!/usr/bin/env python3
"""Validate a release and preview deployment; writes remotely only with --apply."""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
from release import digest, archive_config
from homelab_smoke import load_config, check as smoke_check


def validate(folder, approved_commit):
    manifest = json.loads((folder / 'manifest.json').read_text())
    if manifest.get('schema') != 1 or not re.fullmatch(r'[0-9a-f]{40}', manifest.get('commit', '')):
        raise ValueError('Invalid release manifest')
    if manifest['commit'] != approved_commit:
        raise ValueError('--approved-commit must match the reviewed release commit')
    if manifest['platform'] != 'linux/amd64':
        raise ValueError('This deployment target requires linux/amd64')
    if manifest['image'] != 'gallery-review/server:' + approved_commit:
        raise ValueError('Unexpected image tag')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', manifest['image_id']):
        raise ValueError('Invalid image ID')
    if set(manifest['files']) != {'server-image.tar.gz', 'smoke.json', 'deploy-remote.sh'}:
        raise ValueError('Unexpected release files')
    for name, checksum in manifest['files'].items():
        if digest(folder / name) != checksum:
            raise ValueError('Checksum mismatch: ' + name)
    config_id, config = archive_config(folder / 'server-image.tar.gz', manifest['image'])
    if config_id != manifest.get('image_config_id'):
        raise ValueError('Archive config identity does not match the release manifest')
    if config['os'] + '/' + config['architecture'] != manifest['platform']:
        raise ValueError('Archive architecture does not match the release manifest')
    smoke = json.loads((folder / 'smoke.json').read_text())
    if smoke.get('passed') is not True or smoke.get('image_id') != manifest['image_id']:
        raise ValueError('Missing passing smoke evidence for this exact image')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--host', required=True, help='SSH alias from your private ~/.ssh/config')
    parser.add_argument('--deployment-dir', required=True)
    parser.add_argument('--approved-commit', required=True)
    parser.add_argument('--smoke-config', type=Path, help='Owner-only synthetic account config; required for --apply')
    parser.add_argument('--apply', action='store_true', help='Apply the already reviewed release')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', args.host):
        parser.error('Use a simple SSH host alias')
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', args.deployment_dir) or '..' in Path(args.deployment_dir).parts:
        parser.error('Use a normalized absolute deployment directory without spaces')
    folder = args.bundle.resolve()
    manifest = validate(folder, args.approved_commit)
    print(f"Release {manifest['commit']} ({manifest['platform']}) -> {args.host}:{args.deployment_dir}")
    print('Back up database/configuration; replace only immich-server; verify health.')
    if not args.apply:
        print('PLAN ONLY: no SSH connection, upload, merge, or deployment performed.')
        return
    if not args.smoke_config:
        parser.error('--apply requires --smoke-config for the post-deployment acceptance check')
    smoke_config = load_config(args.smoke_config)
    staging = args.deployment_dir + '/gallery-review-releases/' + manifest['commit']
    subprocess.run(['ssh', args.host, 'umask 077; mkdir -p ' + shlex.quote(staging)], check=True)
    names = ['manifest.json', *manifest['files']]
    subprocess.run(['scp', *[str(folder / name) for name in names], args.host + ':' + staging + '/'], check=True)
    # Recheck transferred files before invoking the reviewed remote script.
    checksum_lines = ''.join(f'{checksum}  {name}\n' for name, checksum in manifest['files'].items())
    subprocess.run(['ssh', args.host, 'cd ' + shlex.quote(staging) + ' && sha256sum -c -'],
                   input=checksum_lines, text=True, check=True)
    remote_args = ['sh', staging + '/deploy-remote.sh', staging, args.deployment_dir,
                   manifest['image'], manifest['image_config_id'], manifest['commit']]
    subprocess.run(['ssh', args.host, shlex.join(remote_args)], check=True)
    smoke_check(smoke_config, manifest['upstream_version'])
    print('Deployment accepted by the scoped read-only smoke check.')


if __name__ == '__main__':
    main()
