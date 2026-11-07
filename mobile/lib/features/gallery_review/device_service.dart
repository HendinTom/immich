import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/features/gallery_review/review_api.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:path_provider/path_provider.dart';

final reviewDeviceServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  return ReviewDeviceService(
    ReviewApi(ref.watch(apiServiceProvider)),
    db.localAssetRepository,
    db.trashedLocalAssetRepository,
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(permissionRepositoryProvider),
  );
});

class ReviewDeviceService {
  ReviewDeviceService(this.api, this.local, this.trashed, this.media, this.permissions);
  final ReviewApi api;
  final LocalAssetRepository local;
  final TrashedLocalAssetRepository trashed;
  final AssetMediaRepository media;
  final DevicePermissionRepository permissions;

  String get scope => '${Store.get(StoreKey.serverEndpoint)}|${Store.get(StoreKey.currentUser).id}';
  bool get localEnabled => Store.get(StoreKey.galleryDeleteThisPhone, true);
  bool get remoteEnabled => Store.get(StoreKey.manageLocalMediaAndroid, false);
  bool get readOnly => Store.get(StoreKey.readonlyModeEnabled, false);

  void _check(String expected) {
    if (scope != expected) {
      throw StateError('Account changed during device sync');
    }
  }

  Future<File> journalFile(String expected) async {
    final folder = await getApplicationSupportDirectory();
    return File('${folder.path}/gallery-device-${sha256.convert(utf8.encode(expected))}.json');
  }

  Future<Map<String, dynamic>> _load(File file) async =>
      file.existsSync() ? jsonDecode(await file.readAsString()) as Map<String, dynamic> : {'receipts': {}};

  Future<void> _save(File file, Map<String, dynamic> state, String expected) async {
    _check(expected);
    final temp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.tmp');
    await temp.writeAsString(jsonEncode(state), flush: true);
    _check(expected);
    await temp.rename(file.path);
  }

  Future<bool> canManageMedia() async =>
      Platform.isAndroid && !readOnly && await permissions.hasManageMediaPermission();

  Future<Map<String, dynamic>?> register() async {
    final expected = scope;
    final file = File('${(await journalFile(expected)).path}.registration');
    final state = await _load(file);
    if (!await api.available()) {
      if (state['protocol'] == 1) {
        throw StateError('Previously managed server no longer supports device policies');
      }
      return null;
    }
    _check(expected);
    final info = Platform.isAndroid ? await DeviceInfoPlugin().androidInfo : null;
    final canManage = info != null && info.version.sdkInt >= 31 && await permissions.hasManageMediaPermission();
    final result = await api.call(
      'device',
      body: {
        'name': info?.model ?? 'This device',
        'platform': Platform.isAndroid
            ? 'android'
            : Platform.isIOS
            ? 'ios'
            : 'other',
        'localEnabled': localEnabled,
        'remoteEnabled': remoteEnabled,
        'canManage': canManage && !readOnly,
      },
    );
    _check(expected);
    state['protocol'] = 1;
    state['deviceId'] = result['deviceId'];
    await _save(file, state, expected);
    return Map<String, dynamic>.from(result as Map);
  }

  /// Called even when remote sync is off: self-requested trash is a separate setting.
  Future<bool> sync() async {
    final expected = scope;
    final file = await journalFile(expected);
    final lock = await File('${file.path}.lock').open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    try {
      if (await register() == null) {
        return false;
      }
      if (!await canManageMedia()) {
        return true;
      }
      final state = await _load(file);
      final receipts = Map<String, dynamic>.from(state['receipts'] as Map? ?? {});
      state['receipts'] = receipts;
      final commands = await api.call('commands') as List;
      for (final raw in commands) {
        _check(expected);
        final command = Map<String, dynamic>.from(raw as Map);
        final checksum = command['checksum'] as String;
        final revision = command['revision'] as String;
        if (readOnly || !(command['local'] == true ? localEnabled : remoteEnabled)) {
          await api.call('commands/ack', body: {'revision': revision, 'status': 'blocked'});
          continue;
        }
        final completed = receipts[checksum] as Map?;
        if (completed?['completedRevision'] == revision) {
          await api.call('commands/ack', body: {'revision': revision, 'status': completed!['status']});
          continue;
        }
        if (command['action'] == 'trash') {
          final previous = receipts[checksum] as Map?;
          final alreadyTrashed = await media.getTrashedIds();
          var assets = (await local.getByChecksum(
            checksum,
          )).whereType<LocalAsset>().where((a) => !alreadyTrashed.contains(a.id)).toList();
          // Persist candidates before touching the OS. This survives process death
          // between native trash and the acknowledgement; retries remain idempotent.
          if (previous == null || previous['revision'] != revision) {
            final known = <String, Map<String, dynamic>>{
              for (final a in previous?['assets'] as List? ?? [])
                (a as Map)['id'] as String: Map<String, dynamic>.from(a),
              for (final a in assets) a.id: _encodeAsset(a),
            };
            assets = known.values.map(_decodeAsset).toList();
            receipts[checksum] = {'assets': known.values.toList(), 'revision': revision};
            await _save(file, state, expected);
          } else {
            assets = (previous['assets'] as List)
                .map((a) => _decodeAsset(Map<String, dynamic>.from(a as Map)))
                .toList();
          }
          _check(expected);
          final remaining = <String>[];
          final missing = <String>{};
          for (final asset in assets.where((a) => !alreadyTrashed.contains(a.id))) {
            if (await media.isPresent(asset.id)) {
              remaining.add(asset.id);
            } else {
              missing.add(asset.id);
            }
          }
          _check(expected);
          if (readOnly || !(command['local'] == true ? localEnabled : remoteEnabled)) {
            await api.call('commands/ack', body: {'revision': revision, 'status': 'blocked'});
            continue;
          }
          final moved = remaining.isEmpty ? <String>[] : await media.deleteAll(remaining);
          final confirmed = {...alreadyTrashed, ...moved};
          _check(expected);
          await trashed.applyTrashedAssets(assets.map((a) => a.id).where(confirmed.contains).toList());
          // A retry after a crash can find the original candidates already in OS
          // trash; retaining the receipt lets a subsequent Undo restore only them.
          final complete = assets.every((a) => confirmed.contains(a.id) || missing.contains(a.id));
          final status = !complete
              ? null
              : assets.isEmpty || missing.isNotEmpty
              ? 'missing'
              : 'applied';
          if (status != null) {
            await api.call('commands/ack', body: {'revision': revision, 'status': status});
          }
        } else {
          final receipt = receipts[checksum] as Map?;
          final assets = (receipt?['assets'] as List? ?? [])
              .map((a) => _decodeAsset(Map<String, dynamic>.from(a as Map)))
              .toList();
          _check(expected);
          final inTrash = await media.getTrashedIds();
          _check(expected);
          if (readOnly || !(command['local'] == true ? localEnabled : remoteEnabled)) {
            await api.call('commands/ack', body: {'revision': revision, 'status': 'blocked'});
            continue;
          }
          final restored = await media.restoreAssetsFromTrash(assets.where((a) => inTrash.contains(a.id)));
          var missing = false;
          for (final asset in assets.where((a) => !inTrash.contains(a.id))) {
            // Includes successful restores whose acknowledgement was interrupted.
            if (await media.isPresent(asset.id)) {
              restored.add(asset.id);
            } else {
              missing = true;
            }
          }
          _check(expected);
          await trashed.applyRestoredAssets(restored);
          if (restored.length == assets.length ||
              (missing && !assets.any((a) => inTrash.contains(a.id) && !restored.contains(a.id)))) {
            receipts[checksum] = {
              'assets': [],
              'completedRevision': revision,
              'status': assets.isEmpty || missing ? 'missing' : 'applied',
            };
            await _save(file, state, expected);
            await api.call(
              'commands/ack',
              body: {'revision': revision, 'status': assets.isEmpty || missing ? 'missing' : 'applied'},
            );
          }
        }
      }
      return true;
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  Future<List<LocalAsset>> filterUploads(List<LocalAsset> assets) async {
    final expected = scope;
    if (assets.isEmpty) {
      return assets;
    }
    final registered = await register();
    _check(expected);
    if (registered == null) {
      return assets;
    }
    final blocked = <String>{};
    final hashes = assets.map((a) => a.checksum).whereType<String>().toSet().toList();
    for (var i = 0; i < hashes.length; i += 500) {
      final result = await api.call('exclusions', body: {'checksums': hashes.skip(i).take(500).toList()});
      _check(expected);
      blocked.addAll((result['blocked'] as List).cast<String>());
    }
    return assets.where((a) => !blocked.contains(a.checksum)).toList();
  }

  static Map<String, dynamic> _encodeAsset(LocalAsset a) => {
    'id': a.id,
    'name': a.name,
    'checksum': a.checksum,
    'type': a.type.index,
    'createdAt': a.createdAt.toIso8601String(),
    'updatedAt': a.updatedAt.toIso8601String(),
  };
  static LocalAsset _decodeAsset(Map<String, dynamic> a) => LocalAsset(
    id: a['id'] as String,
    name: a['name'] as String,
    checksum: a['checksum'] as String?,
    type: AssetType.values[a['type'] as int],
    createdAt: DateTime.parse(a['createdAt'] as String),
    updatedAt: DateTime.parse(a['updatedAt'] as String),
    playbackStyle: AssetPlaybackStyle.unknown,
    isEdited: false,
  );
}
