#!/usr/bin/env python3
"""Run device-policy integration tests in disposable local Docker containers."""
import argparse
from pathlib import Path
import subprocess
import time
import uuid

from lab import require_local_engine

ROOT = Path(__file__).resolve().parents[2]
POSTGRES = 'ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, cwd=ROOT, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', help='Existing server build-stage image; otherwise build current source')
    parser.add_argument('--platform', default='linux/amd64', choices=['linux/amd64', 'linux/arm64'])
    args = parser.parse_args()
    require_local_engine()
    image = args.image or 'gallery-review/policy-tests:local'
    if not args.image:
        run('docker', 'buildx', 'build', '--load', '--platform', args.platform, '--target', 'server',
            '-f', 'server/Dockerfile', '-t', image, '.')
    name = 'gallery-review-policy-' + uuid.uuid4().hex[:12]
    network = name + '-net'
    run('docker', 'network', 'create', network)
    try:
        # No host ports or bind mounts. The password protects only this throwaway database.
        run('docker', 'run', '-d', '--name', name, '--network', network,
            '-e', 'POSTGRES_PASSWORD=synthetic-test-only', '-e', 'POSTGRES_DB=gallery_review_test', POSTGRES)
        for _ in range(60):
            ready = subprocess.run(['docker', 'exec', name, 'pg_isready', '-U', 'postgres'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if ready.returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError('Disposable PostgreSQL did not become ready')
        run('docker', 'run', '--rm', '--platform', args.platform, '--network', network,
            '-e', f'GALLERY_TEST_DATABASE_URL=postgres://postgres:synthetic-test-only@{name}:5432/gallery_review_test',
            '--entrypoint', '/bin/sh', '-w', '/usr/src/app/server', image,
            '-ec', 'pnpm exec vitest run --config test/vitest.config.gallery.mjs')
    finally:
        subprocess.run(['docker', 'rm', '-fv', name], check=False)
        subprocess.run(['docker', 'network', 'rm', network], check=False)


if __name__ == '__main__':
    main()
