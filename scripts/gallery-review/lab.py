#!/usr/bin/env python3
"""Isolated local Compose lifecycle; never accepts a production endpoint."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parents[2]
STATE = ROOT / '.gallery-review'
ENV = STATE / 'lab.env'
COMPOSE = ROOT / 'deployment/gallery-review/compose.yaml'


def run(*args, **kwargs):
    return subprocess.run(list(args), check=True, **kwargs)


def require_local_engine():
    endpoint = os.environ.get('DOCKER_HOST')
    if not endpoint:
        endpoint = subprocess.check_output(
            ['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], text=True).strip()
    if not endpoint.startswith('unix://'):
        raise RuntimeError('The disposable lab requires a local Unix Docker socket, not a remote engine')


def command():
    return ['docker', 'compose', '--project-name', 'gallery-review-lab',
            '--env-file', str(ENV), '-f', str(COMPOSE)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['up', 'down', 'status', 'reset', 'smoke'])
    parser.add_argument('--image', default='ghcr.io/immich-app/immich-server:v3.3.6')
    parser.add_argument('--platform', choices=['linux/arm64', 'linux/amd64'], default='linux/arm64')
    parser.add_argument('--confirm-disposable-reset', action='store_true')
    args = parser.parse_args()
    require_local_engine()
    os.umask(0o077)
    STATE.mkdir(mode=0o700, exist_ok=True)
    if args.action == 'up':
        if not ENV.exists():
            ENV.write_text('GALLERY_DB_PASSWORD=' + secrets.token_hex(24) + '\n')
        if '\n' in args.image or not args.image or any(c.isspace() for c in args.image):
            parser.error('Invalid image reference')
        # Only update non-secret image/platform fields; keep the volume password.
        lines = [line for line in ENV.read_text().splitlines()
                 if not line.startswith(('GALLERY_SERVER_IMAGE=', 'GALLERY_PLATFORM='))]
        ENV.write_text('\n'.join(lines) + f'\nGALLERY_SERVER_IMAGE={args.image}\nGALLERY_PLATFORM={args.platform}\n')
        ENV.chmod(0o600)
        run(*command(), 'up', '-d', '--wait', '--wait-timeout', '240')
        print('Synthetic lab: http://127.0.0.1:22840 (Android emulator: http://10.0.2.2:22840)')
    elif not ENV.exists():
        parser.error('Lab is not initialized; run up first')
    elif args.action == 'down':
        run(*command(), 'down')
    elif args.action == 'status':
        run(*command(), 'ps')
    elif args.action == 'reset':
        if not args.confirm_disposable_reset:
            parser.error('Reset requires --confirm-disposable-reset; deletes only gallery-review-lab volumes')
        run(*command(), 'down', '--volumes')
        (STATE / 'lab-accounts.json').unlink(missing_ok=True)
        (STATE / 'smoke.json').unlink(missing_ok=True)
    elif args.action == 'smoke':
        run('python3', str(ROOT / 'scripts/gallery-review/smoke.py'))


if __name__ == '__main__':
    main()
