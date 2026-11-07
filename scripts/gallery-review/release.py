#!/usr/bin/env python3
"""Build/test an immutable server release locally; never deploys anything."""
import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from lab import ROOT, STATE, require_local_engine


def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def output(args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def clean_revision():
    if output(['git', 'status', '--porcelain', '--untracked-files=all']):
        raise RuntimeError('Commit all source changes before producing release evidence')
    return output(['git', 'rev-parse', 'HEAD'])


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else _hash(stream)


def _hash(stream):
    result = hashlib.sha256()
    for data in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(data)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['linux/amd64', 'linux/arm64'], default='linux/amd64')
    args = parser.parse_args()
    require_local_engine()
    revision = clean_revision()
    os.umask(0o077)
    folder = STATE / 'releases' / revision
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'manifest.json').unlink(missing_ok=True)
    image = f'gallery-review/server:{revision}'
    test_image = image + '-test'
    # The upstream server build stage has the exact source and its dev dependencies.
    run(['docker', 'buildx', 'build', '--platform', args.platform, '--load', '--target', 'server',
         '-f', 'server/Dockerfile', '-t', test_image, '.'])
    run(['docker', 'run', '--rm', '--platform', args.platform, '--entrypoint', '/bin/sh',
         '-w', '/usr/src/app/server', test_image, '-ec', 'pnpm run check && pnpm run test --run'])
    run(['docker', 'buildx', 'build', '--platform', args.platform, '--load',
         '--label', f'org.opencontainers.image.revision={revision}',
         '--build-arg', f'BUILD_ID={revision}', '-f', 'server/Dockerfile', '-t', image, '.'])
    run([sys.executable, 'scripts/gallery-review/lab.py', 'up', '--image', image, '--platform', args.platform])
    run([sys.executable, 'scripts/gallery-review/smoke.py'])
    smoke = json.loads((STATE / 'smoke.json').read_text())
    image_info = json.loads(output(['docker', 'image', 'inspect', image]))[0]
    assert smoke['image_id'] == image_info['Id']
    assert args.platform == image_info['Os'] + '/' + image_info['Architecture']
    assert clean_revision() == revision, 'Source changed during release verification'
    shutil.copyfile(STATE / 'smoke.json', folder / 'smoke.json')
    archive = folder / 'server-image.tar.gz'
    with gzip.open(archive, 'wb') as destination:
        process = subprocess.Popen(['docker', 'save', image], stdout=subprocess.PIPE)
        assert process.stdout is not None
        shutil.copyfileobj(process.stdout, destination)
        process.stdout.close()
        if process.wait():
            raise RuntimeError('Image export failed')
    shutil.copyfile(ROOT / 'scripts/gallery-review/deploy-remote.sh', folder / 'deploy-remote.sh')
    manifest = {
        'schema': 1, 'commit': revision, 'platform': args.platform, 'image': image,
        'image_id': image_info['Id'], 'upstream_version': '3.3.6',
        'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'checks': ['server typecheck', 'server unit tests', 'source image build', 'stock API smoke'],
        'files': {name: digest(folder / name) for name in ('server-image.tar.gz', 'smoke.json', 'deploy-remote.sh')},
        'rollback': 'Image rollback only after verifying database compatibility; no automatic database downgrade.',
    }
    (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Verified release bundle:', folder)
    print('No production changes made. Deploy only after PR review and explicit approval.')


if __name__ == '__main__':
    main()
