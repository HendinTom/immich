import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import deploy
from release import digest


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.commit = 'a' * 40
        self.image_id = 'sha256:' + 'b' * 64
        (self.folder / 'server-image.tar.gz').write_bytes(b'fixture archive')
        (self.folder / 'deploy-remote.sh').write_text('# synthetic test fixture\n')
        (self.folder / 'smoke.json').write_text(json.dumps({'passed': True, 'image_id': self.image_id}))
        self.manifest = {'schema': 1, 'commit': self.commit, 'platform': 'linux/amd64',
                         'image': 'gallery-review/server:' + self.commit, 'image_id': self.image_id,
                         'files': {name: digest(self.folder / name) for name in
                                   ('server-image.tar.gz', 'smoke.json', 'deploy-remote.sh')}}
        self.save()

    def save(self):
        (self.folder / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_valid_bundle(self):
        self.assertEqual(deploy.validate(self.folder, self.commit)['commit'], self.commit)

    def test_unapproved_commit_rejected(self):
        with self.assertRaises(ValueError):
            deploy.validate(self.folder, 'c' * 40)

    def test_wrong_architecture_rejected(self):
        self.manifest['platform'] = 'linux/arm64'
        self.save()
        with self.assertRaises(ValueError):
            deploy.validate(self.folder, self.commit)

    def test_tampered_archive_rejected(self):
        (self.folder / 'server-image.tar.gz').write_bytes(b'changed')
        with self.assertRaises(ValueError):
            deploy.validate(self.folder, self.commit)

    def test_evidence_for_different_image_rejected(self):
        smoke = self.folder / 'smoke.json'
        smoke.write_text(json.dumps({'passed': True, 'image_id': 'sha256:' + 'c' * 64}))
        self.manifest['files']['smoke.json'] = digest(smoke)
        self.save()
        with self.assertRaises(ValueError):
            deploy.validate(self.folder, self.commit)

    def test_path_traversal_rejected(self):
        self.manifest['files']['../../outside'] = 'a' * 64
        self.save()
        with self.assertRaises(ValueError):
            deploy.validate(self.folder, self.commit)

    def test_default_plan_never_connects_or_deploys(self):
        argv = ['deploy.py', str(self.folder), '--host', 'example-host', '--deployment-dir', '/srv/immich',
                '--approved-commit', self.commit]
        with patch('sys.argv', argv), patch('subprocess.run') as run, contextlib.redirect_stdout(io.StringIO()):
            deploy.main()
            run.assert_not_called()

    def test_shell_syntax_in_host_rejected(self):
        argv = ['deploy.py', str(self.folder), '--host', 'host;false', '--deployment-dir', '/srv/immich',
                '--approved-commit', self.commit, '--apply']
        with patch('sys.argv', argv), patch('subprocess.run') as run, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                deploy.main()
            run.assert_not_called()

class RemoteDeploymentTests(unittest.TestCase):
    def setUp(self):
        import gzip
        import os
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.deployment = self.root / 'deployment'
        self.deployment.mkdir()
        (self.deployment / '.env').write_text('private-test-config\n')
        (self.deployment / 'docker-compose.yml').write_text('services: {}\n')
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        with gzip.open(self.bundle / 'server-image.tar.gz', 'wb') as stream:
            stream.write(b'synthetic image archive')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands.log'
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                    'TEST_COMMAND_LOG': str(self.log)}
        self.executable('uname', '#!/bin/sh\nprintf "x86_64\\n"\n')
        self.executable('curl', '#!/bin/sh\nexit 0\n')
        self.executable('docker', '''#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_COMMAND_LOG"
case "$*" in
  'compose ps -q immich-server') echo fixture-container ;;
  'inspect --format {{.Image}} fixture-container') echo sha256:old-image ;;
  'compose exec -T database sh -c '*)
    if test "${FAIL_DUMP:-0}" = 1; then exit 1; fi
    echo synthetic-database-dump ;;
  'compose exec -T database pg_restore --list') cat >/dev/null; echo archive-list ;;
  'load') cat >/dev/null ;;
  'image inspect --format {{.Id}} '*) echo sha256:new-image ;;
  'image inspect --format {{.Os}}/{{.Architecture}} '*) echo linux/amd64 ;;
  'compose up '*) test "${FAIL_HEALTH:-0}" != 1 ;;
esac
''')

    def executable(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o700)

    def run_deploy(self):
        import subprocess
        return subprocess.run(['sh', str(Path(deploy.__file__).with_name('deploy-remote.sh')),
                               str(self.bundle), str(self.deployment), 'gallery-review/server:fixture',
                               'sha256:new-image', 'a' * 40], env=self.env, capture_output=True, text=True)

    def test_unrelated_override_is_never_overwritten(self):
        override = self.deployment / 'docker-compose.override.yml'
        override.write_text('existing unrelated configuration\n')
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(override.read_text(), 'existing unrelated configuration\n')
        self.assertFalse(self.log.exists())

    def test_failed_backup_prevents_replacement(self):
        self.env['FAIL_DUMP'] = '1'
        self.assertNotEqual(self.run_deploy().returncode, 0)
        self.assertNotIn('compose up', self.log.read_text())
        self.assertFalse((self.deployment / 'docker-compose.override.yml').exists())

    def test_failed_health_retains_backup_and_does_not_downgrade(self):
        self.env['FAIL_HEALTH'] = '1'
        self.assertNotEqual(self.run_deploy().returncode, 0)
        backups = list((self.deployment / 'upgrade-backups').glob('*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / '.env').read_text(), 'private-test-config\n')
        self.assertEqual((backups[0] / 'database.dump').read_text(), 'synthetic-database-dump\n')
        commands = self.log.read_text()
        self.assertEqual(commands.count('compose up'), 1)
        self.assertNotIn('--volumes', commands)
        self.assertNotIn('compose down', commands)
        self.assertFalse((self.deployment / '.gallery-review-deploy.lock').exists())

    def test_success_replaces_only_application_after_backup(self):
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.log.read_text()
        self.assertLess(commands.index('pg_restore --list'), commands.index('compose up'))
        self.assertIn('compose up -d --no-deps --wait --wait-timeout 240 immich-server', commands)
        self.assertNotIn('compose down', commands)


class LocalEngineTests(unittest.TestCase):
    def test_remote_docker_host_is_rejected(self):
        from lab import require_local_engine
        with patch.dict('os.environ', {'DOCKER_HOST': 'ssh://remote'}, clear=True):
            with self.assertRaises(RuntimeError):
                require_local_engine()

    def test_context_override_cannot_hide_remote_engine(self):
        from lab import require_local_engine
        with patch.dict('os.environ', {'DOCKER_HOST': 'unix:///local.sock', 'DOCKER_CONTEXT': 'remote'}, clear=True):
            with patch('subprocess.check_output', return_value='ssh://remote'):
                with self.assertRaises(RuntimeError):
                    require_local_engine()

    def test_local_socket_is_accepted(self):
        from lab import require_local_engine
        with patch.dict('os.environ', {'DOCKER_HOST': 'unix:///local.sock'}, clear=True):
            require_local_engine()


if __name__ == '__main__':
    unittest.main()
