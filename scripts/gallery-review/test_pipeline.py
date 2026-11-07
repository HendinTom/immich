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


if __name__ == '__main__':
    unittest.main()
