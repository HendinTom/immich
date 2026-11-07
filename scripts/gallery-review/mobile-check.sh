#!/usr/bin/env bash
# Local mobile CI entrypoint. No backend, emulator, account or production access.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root/mobile"
bootstrap=false
build=false
for arg in "$@"; do
  case "$arg" in
    --bootstrap) bootstrap=true ;;
    --build) build=true ;;
    *) echo "Usage: $0 [--bootstrap] [--build]" >&2; exit 2 ;;
  esac
done
if "$bootstrap"; then
  # Follow upstream code generation, without its destructive clean task.
  (cd "$root/open-api" && bash bin/generate-dart-sdk.sh)
  flutter pub get --enforce-lockfile
  dart run build_runner build
  dart run drift_dev make-migrations
  for input in pigeon/*.dart; do dart run pigeon --input "$input"; done
  dart run easy_localization:generate -S ../i18n
  dart run bin/generate_keys.dart
else
  test -f generated/openapi/lib/api.dart || { echo 'Run --bootstrap in a new checkout first.' >&2; exit 1; }
  flutter pub get --enforce-lockfile
fi
dart format --output=none --set-exit-if-changed lib/features/gallery_review test/features/gallery_review
dart analyze lib/features/gallery_review test/features/gallery_review \
  lib/domain/services/sync_stream.service.dart lib/domain/services/local_sync.service.dart lib/providers/infrastructure/sync.provider.dart \
  lib/repositories/asset_media.repository.dart lib/presentation/actions/delete.action.dart \
  lib/services/foreground_upload.service.dart lib/services/background_upload.service.dart \
  lib/widgets/settings/advanced_settings.dart
flutter test --no-pub test/features/gallery_review test/domain/services/sync_stream_service_test.dart test/domain/services/local_sync_service_test.dart test/medium/repositories/trashed_local_asset_repository_test.dart
if "$build"; then
  flutter build apk --debug --target-platform android-arm64 --no-pub
  python3 - "$root" <<'PY'
import hashlib,json,shutil,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]); revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
dirty=bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=all'],cwd=root,text=True).strip())
out=root/'.gallery-review/mobile'/revision;out.mkdir(parents=True,exist_ok=True)
apk=out/'gallery-review-debug.apk';shutil.copyfile(root/'mobile/build/app/outputs/flutter-apk/app-debug.apk',apk)
checksum=hashlib.sha256(apk.read_bytes()).hexdigest()
(apk.with_suffix('.apk.sha256')).write_text(checksum+'  '+apk.name+'\n')
(out/'manifest.json').write_text(json.dumps({'commit':revision,'dirty':dirty,'artifact':apk.name,'sha256':checksum,'platform':'android-arm64','signing':'debug','checks':['format','targeted analysis','review and native sync tests','APK build']},indent=2)+'\n')
print('Debug APK:',apk)
print('Source has uncommitted changes.' if dirty else 'Artifact matches the committed source revision.')
PY
fi
