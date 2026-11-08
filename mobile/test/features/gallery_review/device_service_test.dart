import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/features/gallery_review/device_service.dart';
import 'package:immich_mobile/features/gallery_review/review_api.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqlite3/sqlite3.dart';

class _Api extends Mock implements ReviewApi {}

class _Local extends Mock implements LocalAssetRepository {}

class _Trash extends Mock implements TrashedLocalAssetRepository {}

class _Media extends Mock implements AssetMediaRepository {}

class _Permission extends Mock implements DevicePermissionRepository {}

class _Device extends ReviewDeviceService {
  _Device(super.api, super.local, super.trashed, super.media, super.permissions, this.file);
  final File file;
  bool enabled = true;
  @override
  String get scope => 'synthetic-account';
  @override
  bool get localEnabled => enabled;
  @override
  bool get remoteEnabled => enabled;
  @override
  bool get readOnly => false;
  @override
  Future<bool> canManageMedia() async => true;
  @override
  Future<File> journalFile(String expected) async => file;
  @override
  Future<Map<String, dynamic>?> register({String? replaceDeviceId}) async => {'protocol': 1};
}

void main() {
  late Directory folder;
  late _Api api;
  late _Local local;
  late _Trash trash;
  late _Media media;
  late _Device device;
  final asset = LocalAsset(
    id: '42',
    name: 'synthetic.jpg',
    checksum: 'checksum',
    type: AssetType.image,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    playbackStyle: AssetPlaybackStyle.unknown,
    isEdited: false,
  );
  Map<String, dynamic> command(String action) => {
    'checksum': 'checksum',
    'revision': action,
    'action': action,
    'local': true,
  };
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('gallery-device-test-');
    api = _Api();
    local = _Local();
    trash = _Trash();
    media = _Media();
    device = _Device(api, local, trash, media, _Permission(), File('${folder.path}/journal.json'));
    when(() => api.call('commands/ack', body: any(named: 'body'))).thenAnswer((_) async => {});
    when(() => trash.applyTrashedAssets(any())).thenAnswer((_) async {});
    when(() => trash.applyRestoredAssets(any())).thenAnswer((_) async {});
    when(() => media.getTrashedIds()).thenAnswer((_) async => {});
    when(() => media.isPresent(any())).thenAnswer((_) async => true);
    when(() => local.getByChecksum('checksum')).thenAnswer((_) async => [asset]);
  });
  tearDown(() async => folder.delete(recursive: true));
  test('trash receipt survives a lost acknowledgement and retry recognizes OS trash', () async {
    when(() => api.call('commands')).thenAnswer((_) async => [command('trash')]);
    when(() => media.deleteAll(['42'])).thenAnswer((_) async => ['42']);
    when(() => api.call('commands/ack', body: any(named: 'body'))).thenThrow(Exception('offline'));
    await expectLater(device.sync(), throwsException);
    expect(jsonDecode(await device.file.readAsString())['receipts']['checksum']['assets'][0]['id'], '42');
    when(() => media.getTrashedIds()).thenAnswer((_) async => {'42'});
    when(() => api.call('commands/ack', body: any(named: 'body'))).thenAnswer((_) async => {});
    await device.sync();
    verify(() => media.deleteAll(['42'])).called(1);
    verify(() => api.call('commands/ack', body: {'revision': 'trash', 'status': 'applied'})).called(2);
  });
  test('restoration without a receipt never touches unrelated phone trash', () async {
    when(() => api.call('commands')).thenAnswer((_) async => [command('restore')]);
    when(() => media.getTrashedIds()).thenAnswer((_) async => {'unrelated'});
    when(() => media.restoreAssetsFromTrash(any())).thenAnswer((_) async => []);
    await device.sync();
    final assets = verify(() => media.restoreAssetsFromTrash(captureAny())).captured.single as Iterable;
    expect(assets, isEmpty);
    verify(() => api.call('commands/ack', body: {'revision': 'restore', 'status': 'missing'})).called(1);
  });
  test('opt-out blocks an already fetched command before any native mutation', () async {
    device.enabled = false;
    when(() => api.call('commands')).thenAnswer((_) async => [command('trash')]);
    await device.sync();
    verifyNever(() => media.deleteAll(any()));
    verify(() => api.call('commands/ack', body: {'revision': 'trash', 'status': 'blocked'})).called(1);
  });
  test('missing native copy is reported rather than retried forever', () async {
    when(() => api.call('commands')).thenAnswer((_) async => [command('trash')]);
    when(() => media.isPresent('42')).thenAnswer((_) async => false);
    await device.sync();
    verifyNever(() => media.deleteAll(any()));
    verify(() => api.call('commands/ack', body: {'revision': 'trash', 'status': 'missing'})).called(1);
  });
  test('lost restore acknowledgement retains its result without restoring twice', () async {
    when(() => api.call('commands')).thenAnswer((_) async => [command('trash')]);
    when(() => media.deleteAll(['42'])).thenAnswer((_) async => ['42']);
    await device.sync();
    when(() => api.call('commands')).thenAnswer((_) async => [command('restore')]);
    when(() => media.getTrashedIds()).thenAnswer((_) async => {'42'});
    when(() => media.restoreAssetsFromTrash(any())).thenAnswer((_) async => ['42']);
    when(
      () => api.call('commands/ack', body: {'revision': 'restore', 'status': 'applied'}),
    ).thenThrow(Exception('offline'));
    await expectLater(device.sync(), throwsException);
    when(
      () => api.call('commands/ack', body: {'revision': 'restore', 'status': 'applied'}),
    ).thenAnswer((_) async => {});
    await device.sync();
    verify(() => media.restoreAssetsFromTrash(any())).called(1);
  });
  test('another worker connection owns delivery without losing managed mode', () async {
    final lease = sqlite3.open('${device.file.path}.lease.sqlite');
    lease.execute('BEGIN EXCLUSIVE');
    try {
      expect(await device.sync(), isTrue);
      verifyNever(() => api.call('commands'));
    } finally {
      lease.close();
    }
    when(() => api.call('commands')).thenAnswer((_) async => []);
    expect(await device.sync(), isTrue);
    verify(() => api.call('commands')).called(1);
  });
}
