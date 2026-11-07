import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:mocktail/mocktail.dart';

class _Native extends Mock implements NativeSyncApi {}

class _Storage extends Mock implements StorageRepository {}

void main() {
  test('native Trash decodes Pigeon nested channel lists', () async {
    final native = _Native();
    final asset = PlatformAsset(
      id: '42',
      name: 'synthetic.jpg',
      type: 1,
      durationMs: 0,
      orientation: 0,
      isFavorite: false,
      playbackStyle: PlatformAssetPlaybackStyle.unknown,
    );
    // This is exactly the lazy cast returned by the generated channel method.
    final wire = <Object?, Object?>{
      'album': <Object?>[asset],
    }.cast<String, List<PlatformAsset>>();
    when(() => native.getTrashedAssets()).thenAnswer((_) async => wire);
    expect(await AssetMediaRepository(native, _Storage()).getTrashedIds(), {'42'});
  });
}
