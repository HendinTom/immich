#!/bin/sh
# Invoked only by deploy.py --apply with an explicitly approved release commit.
set -eu
umask 077
bundle=$1
deployment=$2
image=$3
expected_config_id=$4
approved_commit=$5
cd "$deployment"
test -f docker-compose.yml
test -f .env
lock=.gallery-review-deploy.lock
mkdir "$lock" || { echo 'Another deployment holds the lock; inspect it before retrying.' >&2; exit 1; }
trap 'rmdir "$lock"' EXIT HUP INT TERM
override=docker-compose.override.yml
if test -f "$override" && ! head -n 1 "$override" | grep -qx '# Managed by Gallery Review deployment'; then
  echo 'Existing override is not managed by this pipeline; refusing to overwrite it.' >&2
  exit 1
fi
test "$(uname -m)" = x86_64
old_container=$(docker compose ps -q immich-server)
test -n "$old_container"
old_image=$(docker inspect --format '{{.Image}}' "$old_container")
# Back up before loading/replacing the application. Database and media mounts are unchanged.
backup="upgrade-backups/gallery-review-$(date -u +%Y%m%d-%H%M%S)-$approved_commit"
mkdir -p "$backup"
cp .env docker-compose.yml "$backup/"
if test -f "$override"; then cp "$override" "$backup/previous-override.yml"; fi
printf '%s\n' "$old_image" > "$backup/previous-image-id.txt"
# Retain an addressable local image even after the application container is replaced.
docker image tag "$old_image" "gallery-review/rollback:$approved_commit"
docker compose exec -T database sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$backup/database.dump"
test -s "$backup/database.dump"
docker compose exec -T database pg_restore --list < "$backup/database.dump" > "$backup/database-list.txt"
# The target uses the classic Docker image store: .Id is the config digest.
# Docker Desktop/containerd reports an OCI index digest instead; the release
# records both and verifies the exported config and layer identities locally.
# The archive is checked by the caller and again in the staging directory.
gzip -dc "$bundle/server-image.tar.gz" | docker load
test "$(docker image inspect --format '{{.Id}}' "$image")" = "$expected_config_id"
test "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")" = linux/amd64
printf '# Managed by Gallery Review deployment\nservices:\n  immich-server:\n    image: %s\n' "$image" > "$override.new"
mv "$override.new" "$override"
if ! docker compose up -d --no-deps --wait --wait-timeout 240 immich-server; then
  echo "Health check failed. Previous image and private backup retained at $backup." >&2
  echo 'No automatic downgrade: check migration compatibility before reverting.' >&2
  exit 1
fi
# Loopback health check, no production account or media access.
curl --fail --silent --show-error http://127.0.0.1:2283/api/server/ping >/dev/null
printf 'Deployed %s. Previous image and private backup: %s\n' "$approved_commit" "$backup"
printf 'Run the separately scoped synthetic-account smoke check before declaring the release accepted.\n'
