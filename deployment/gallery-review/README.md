# Gallery Review: local tests and manually approved deployment

This foundation does not change Immich's server behavior. It establishes the
release path for subsequent device-policy work. Mobile and server changes are
reviewed in separate PRs against `gallery-main`, initially pinned to v3.3.6.
Neither a push nor a merge deploys anything to the homelab.

## 1. Disposable MacBook lab

Prerequisites: Docker Desktop, Python 3.10+, Git. The MacBook uses Linux ARM64
containers; the current deployment target uses Linux AMD64. The lab refuses a
remote Docker endpoint and uses only the `gallery-review-lab` Compose project.

```sh
python3 scripts/gallery-review/lab.py up
python3 scripts/gallery-review/lab.py smoke
python3 scripts/gallery-review/lab.py status
python3 scripts/gallery-review/lab.py down
```

The server listens only on `127.0.0.1:22840`. Android emulator endpoint:
`http://10.0.2.2:22840`. The lab has its own database and media volumes, no
production mounts, and no published database/Redis ports. ML is disabled in the
synthetic lab by the smoke setup; it is not needed for basic upload/trash/restore.

Private random credentials are generated under ignored `.gallery-review/` with
owner-only permissions. The smoke test bootstraps a synthetic administrator and
two non-admin accounts. It verifies ownership checks, upload, duplicate handling,
recoverable Trash, restore, and original-byte checksum preservation. It restores
the fixture before exiting. These API checks do not prove device-local deletion,
restoration, background execution, video playback or the future policy features.

Only this explicit command deletes the **disposable lab** volumes:

```sh
python3 scripts/gallery-review/lab.py reset --confirm-disposable-reset
```

## 2. Verify the pipeline itself

```sh
python3 -m unittest discover -s scripts/gallery-review -p 'test_*.py' -v
sh -n scripts/gallery-review/deploy-remote.sh
```

Negative tests cover an unapproved commit, wrong CPU architecture, modified
archive, wrong-image smoke evidence, unexpected file paths, and shell syntax in
host names. The default deploy command is tested to perform no remote calls.

## 3. Build a release from committed source

```sh
python3 scripts/gallery-review/release.py --platform linux/amd64
```

This requires a clean checkout and records the full Git commit. It builds the
upstream server build stage, runs the server typecheck and unit tests, then
builds the complete application image (including web). It runs that exact image
in the disposable lab and repeats the stock API smoke before exporting it.
For full source builds on the 16 GiB MacBook, allocate 8 GiB memory and 2 GiB
swap to Docker Desktop; the default 4 GiB allocation exhausted memory compiling
the web frontend. Server tests use one worker to limit memory pressure.
AMD64 uses emulation on the MacBook and is slower than native ARM64 development.
An ARM64 development verification is possible with `--platform linux/arm64`, but
that bundle is deliberately rejected by the AMD64 deployment gate.

The ignored `.gallery-review/releases/COMMIT/` bundle contains the compressed
image, checksums, image ID/platform, commit, smoke evidence and deployment script.
A manifest is written only after all checks pass. Changing source afterward
requires a new release. Production deploys the tested image, not a rebuild.

## 4. Review before deployment

Open the server and mobile PRs separately. Review and merge them explicitly; do
not enable auto-merge. After merging, build a new release from the merged source.
Confirm that the release manifest identifies the approved commit. Mobile APKs
are distributed separately and are not installed by a server deployment.

Prepare an owner-only synthetic account configuration outside Git:

```json
{
  "api_url": "https://your-private-gallery.example/api",
  "email": "synthetic-user@example.invalid",
  "password": "REPLACE_LOCALLY",
  "expected_user_id": "REPLACE_WITH_SYNTHETIC_NON_ADMIN_USER_ID",
  "expected_asset_names": ["synthetic-photo.jpg", "synthetic-video.mp4"]
}
```

Set mode 0600. The post-deployment check validates the exact account and exact
synthetic inventory; it never reads personal photo content or mutates media.

Preview a deployment (no SSH or writes occur):

```sh
python3 scripts/gallery-review/deploy.py .gallery-review/releases/COMMIT \
  --host YOUR_SSH_ALIAS --deployment-dir /absolute/path/to/immich \
  --approved-commit COMMIT
```

Only after the owner approves the PRs, merged release and rollout, repeat with:

```sh
python3 scripts/gallery-review/deploy.py .gallery-review/releases/COMMIT \
  --host YOUR_SSH_ALIAS --deployment-dir /absolute/path/to/immich \
  --approved-commit COMMIT --smoke-config /private/path/synthetic-account.json \
  --apply
```

The deployment verifies transferred checksums, obtains a lock, saves the previous
image/configuration and a PostgreSQL custom-format dump, validates its archive
listing, and replaces **only immich-server**. It writes a managed default Compose
override so later ordinary `docker compose` commands keep the selected image.
An existing unrelated override is never overwritten. ML, database, Redis, proxy,
legacy reviewer, media mounts and credentials are left in place.

Container health, server ping and the scoped synthetic login/inventory must pass.
A successful database archive listing is not a full restore rehearsal. The dump
does not include photo files; the existing media backup policy remains necessary.

## Rollback

On failure, the command exits nonzero and retains the old image, dump and prior
configuration. It deliberately does not auto-downgrade across unknown migrations.
Determine migration compatibility first. If compatible, restore the previous
managed override (or remove the new one if none existed) and run
`docker compose up -d --no-deps --wait immich-server` using the retained old image.
If the original image was mutable, use the saved exact image ID/rollback tag.

If a database restore is required, stop writes and use a separately reviewed
restore procedure. Never automatically restore a pre-deployment database over
new user data. Rehearse this against disposable volumes before a release that
adds schema changes. Upcoming device-policy migrations must be additive where
possible and document their own compatibility/rollback constraints.

## GitHub checks

`Gallery server foundation` runs pipeline gate tests and stock API smoke on PRs.
Its manual workflow also performs the full source build/test/release verification
on an AMD64 runner. It never receives SSH credentials or deploys. Build evidence
is retained as an artifact. The deployable image bundle is produced locally by
the same command; no public image registry or production secret is required.

The fork's inherited Immich release workflows require upstream-only secrets and
should be disabled in the fork. The Gallery workflows replace them for this
branch; upstream source workflow files remain unchanged.
