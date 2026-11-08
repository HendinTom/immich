import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart' as settings;
import 'package:immich_mobile/features/gallery_review/device_service.dart';
import 'package:immich_mobile/features/gallery_review/review_delivery_status.dart';
import 'package:immich_mobile/features/gallery_review/review_session.dart';
import 'package:immich_mobile/features/gallery_review/review_swipe_card.dart';
import 'package:immich_mobile/features/gallery_review/review_video.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:openapi/api.dart';
import 'package:path_provider/path_provider.dart';

@RoutePage()
class GalleryReviewPage extends ConsumerStatefulWidget {
  const GalleryReviewPage({super.key});
  @override
  ConsumerState<GalleryReviewPage> createState() => _GalleryReviewPageState();
}

class _GalleryReviewPageState extends ConsumerState<GalleryReviewPage> {
  ReviewSession? _session;
  AssetResponseDto? _asset;
  final List<AssetResponseDto> _buffer = [];
  final Set<String> _prefetching = {};
  List<AlbumResponseDto> _albums = [];
  String? _album;
  DateTimeRange? _dates;
  String? _error;
  String? _scope;
  bool _busy = true;
  bool _managed = false;
  bool _started = false;
  bool _serverSelected = true;
  List<Map<String, dynamic>> _devices = [];
  final Set<String> _selectedDevices = {};
  String? _deliveryStatus;
  late final _delivery = ReviewDeliveryStatus(
    load: _loadDeliveryStatus,
    publish: (status) {
      if (mounted && _scope == _currentScope) {
        setState(() => _deliveryStatus = status);
      }
    },
  );
  bool get _trashMode => _album == '__trash__';

  String get _currentScope => '${settings.Store.get(StoreKey.serverEndpoint)}|${ref.read(currentUserProvider)?.id}';
  void _checkAccount() {
    if (_scope != _currentScope || ref.read(currentUserProvider) == null) {
      throw StateError('Account changed. Reopen Review.');
    }
  }

  Future<void> _replaceLegacyDevice(Map<String, dynamic> device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace this old device entry?'),
        content: Text(
          'Only continue if "${device['name']}" is an earlier installation on this phone. '
          'Its pending phone actions will be cancelled and the old entry hidden. '
          'Photos will not be deleted or restored. Other phones should keep their own entries.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Replace old entry')),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _run(() async {
      _checkAccount();
      final service = ref.read(reviewDeviceServiceProvider);
      await service.register(replaceDeviceId: device['id'] as String);
      final devices = (await service.api.call('devices') as List)
          .map((d) => Map<String, dynamic>.from(d as Map))
          .toList();
      _checkAccount();
      _devices = devices;
      _selectedDevices.remove(device['id']);
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _delivery.dispose();
    super.dispose();
  }

  RemoteImageProvider _preview(AssetResponseDto asset) => RemoteImageProvider(
    url: getThumbnailUrlForRemoteId(asset.id, type: AssetMediaSize.preview),
    decodeSize: MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context),
  );

  void _showAsset(AssetResponseDto? item) {
    _asset = item;
    if (!mounted || _scope != _currentScope) {
      return;
    }
    // Bound speculative downloads and decode to the screen size. The displayed
    // image uses the same provider key, so advancing reuses the warmed cache.
    for (final next in _buffer.take(2).where((a) => a.type != AssetTypeEnum.VIDEO)) {
      if (_prefetching.length >= 2 || !_prefetching.add(next.id)) {
        continue;
      }
      unawaited(
        precacheImage(_preview(next), context, onError: (_, _) {}).whenComplete(() => _prefetching.remove(next.id)),
      );
    }
  }

  Future<void> _initialize() async {
    try {
      _scope = _currentScope;
      _checkAccount();
      final folder = await getApplicationSupportDirectory();
      final key = sha256.convert(utf8.encode(_scope!));
      final file = File('${folder.path}/gallery-review-$key.json');
      final deviceService = ref.read(reviewDeviceServiceProvider);
      _managed = await deviceService.register() != null;
      _checkAccount();
      if (_managed) {
        _devices = (await deviceService.api.call('devices') as List)
            .map((d) => Map<String, dynamic>.from(d as Map))
            .toList();
        _selectedDevices.addAll(
          _devices.where((d) => d['current'] == true && d['enabled'] == true).map((d) => d['id'] as String),
        );
      }
      _session = ReviewSession(
        applyOperation: _managed
            ? (operation) async {
                _checkAccount();
                if (ref.read(readonlyModeProvider)) {
                  throw StateError('Read-only mode is enabled');
                }
                await deviceService.api.call('decisions', body: operation);
                _checkAccount();
              }
            : null,
        undoOperation: _managed
            ? (id) async {
                _checkAccount();
                if (ref.read(readonlyModeProvider)) {
                  throw StateError('Read-only mode is enabled');
                }
                await deviceService.api.call('decisions/$id/undo', body: {});
                _checkAccount();
              }
            : null,
        saved: file.existsSync() ? await file.readAsString() : null,
        save: (data) async {
          _checkAccount();
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(data, flush: true);
          await temporary.rename(file.path);
        },
        trash: (id) async {
          _checkAccount();
          if (ref.read(readonlyModeProvider)) {
            throw StateError("Read-only mode is enabled");
          }
          final features = await ref.read(Store.api).serverInfoApi.getServerFeatures();
          _checkAccount();
          if (features?.trash != true) {
            throw StateError('Server trash is disabled');
          }
          final asset = await ref.read(Store.api).assetsApi.getAssetInfo(id);
          _checkAccount();
          if (asset == null || asset.ownerId != ref.read(currentUserProvider)!.id) {
            throw StateError('Asset is not owned by this account');
          }
          await ref.read(assetServiceProvider).trash([id]);
        },
        restore: (id) async {
          _checkAccount();
          if (ref.read(readonlyModeProvider)) {
            throw StateError("Read-only mode is enabled");
          }
          await ref.read(assetServiceProvider).restoreTrash([id]);
        },
      );
      _albums = await ref.read(Store.api).albumsApi.getAllAlbums(isOwned: true) ?? [];
      if (_session!.trashMode) {
        _album = '__trash__';
      }
      // Pending mutations retain their original destinations across restart.
      if (_session!.pending) {
        _started = true;
        await _loadNext();
      }
    } catch (_) {
      _error = 'Could not load review progress. Try again; existing progress has not been reset.';
    }
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _loadNext({String? preferredId, bool reset = false}) async {
    if (reset) {
      _buffer.clear();
    }
    _checkAccount();
    final api = ref.read(Store.api);
    final userId = ref.read(currentUserProvider)!.id;
    final pendingId = _session!.pending ? _session!.lastId : preferredId;
    if (pendingId != null) {
      final item = await api.assetsApi.getAssetInfo(pendingId);
      _checkAccount();
      if (item != null && item.ownerId == userId) {
        // The visible next card has already been removed from the buffer.
        // Put it back before Undo replaces it, otherwise deciding the restored
        // card again skips that still-unreviewed card until the next refill.
        final displaced = _asset;
        if (displaced != null && displaced.id != item.id && !_session!.reviewed.contains(displaced.id)) {
          _buffer.removeWhere((queued) => queued.id == displaced.id);
          _buffer.insert(0, displaced);
        }
        _showAsset(item);
        return;
      }
    }
    while (_buffer.isNotEmpty) {
      final item = _buffer.removeAt(0);
      if (!_session!.reviewed.contains(item.id)) {
        _showAsset(item);
        return;
      }
    }
    // Consume a page locally, then restart search when refilling. Deletions
    // cannot shift a retained page offset and skip an unreviewed item.
    var page = 1;
    while (true) {
      final result = await api.searchApi.searchAssets(
        MetadataSearchDto(
          albumIds: Optional.present(_album == null || _trashMode ? [] : [_album!]),
          page: Optional.present(page),
          size: const Optional.present(50),
          takenAfter: _dates == null ? const Optional.absent() : Optional.present(_dates!.start),
          takenBefore: _dates == null
              ? const Optional.absent()
              : Optional.present(
                  DateTime(
                    _dates!.end.year,
                    _dates!.end.month,
                    _dates!.end.day + 1,
                  ).subtract(const Duration(microseconds: 1)),
                ),
          withDeleted: Optional.present(_trashMode),
        ),
      );
      _checkAccount();
      if (result == null) {
        throw StateError('No search response');
      }
      for (final item in result.assets.items) {
        if (item.ownerId == userId && item.isTrashed == _trashMode && !_session!.reviewed.contains(item.id)) {
          _buffer.add(item);
        }
      }
      if (_buffer.isNotEmpty) {
        _showAsset(_buffer.removeAt(0));
        return;
      }
      if (result.assets.nextPage == null) {
        _showAsset(null);
        return;
      }
      final next = int.tryParse(result.assets.nextPage!);
      if (next == null || next <= page) {
        throw StateError('Invalid search pagination');
      }
      page = next;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      _error = 'The action could not be confirmed. Your place is saved. Retry or use Undo.';
    }
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _decide(bool trash) async {
    final asset = _asset;
    if (asset == null || _session == null) {
      return;
    }
    await _run(() async {
      await _session!.decide(
        asset.id,
        toTrash: trash,
        destinations: {
          'server': _trashMode || _serverSelected,
          'devices': _trashMode ? <String>[] : _selectedDevices.toList(),
        },
      );
      // Keep/Nothing never starts a device sync. Destructive decisions have
      // already been saved and accepted before delivery runs independently.
      _delivery.refresh(_managed ? (_session!.operation?['operationId'] as String?) : null);
      _asset = null;
      await _loadNext();
    });
  }

  Future<void> _undo() async {
    await _run(() async {
      final id = _session!.lastId;
      final operationId = _session!.operation?['operationId'] as String?;
      await _session!.undo();
      _delivery.refresh(_managed ? operationId : null);
      await _loadNext(preferredId: id);
    });
  }

  Widget _swipeMedia(Widget media, String assetId, bool enabled, bool trashEnabled) => ReviewSwipeCard(
    key: ValueKey(assetId),
    enabled: enabled && _session?.pending != true,
    trashMode: _trashMode,
    trashEnabled: _trashMode || trashEnabled,
    keepEnabled: !_trashMode || trashEnabled,
    onKeep: () => unawaited(_decide(_trashMode)),
    onTrash: () => unawaited(_decide(!_trashMode)),
    child: media,
  );

  Future<String> _loadDeliveryStatus(String operationId) async {
    _checkAccount();
    try {
      final service = ref.read(reviewDeviceServiceProvider);
      await service.sync();
      _checkAccount();
      final result = await service.api.call('decisions/$operationId');
      _checkAccount();
      final deliveries = result['devices'] as List;
      final summaries = <String>[];
      for (final entry in {
        'applied': 'updated',
        'pending': 'pending',
        'blocked': 'disabled',
        'cancelled': 'cancelled after reinstall',
        'missing': 'without a matching copy',
        'superseded': 'superseded',
      }.entries) {
        final count = deliveries.where((d) => d['status'] == entry.key).length;
        if (count > 0) {
          summaries.add('$count device${count == 1 ? '' : 's'} ${entry.value}');
        }
      }
      return summaries.isEmpty ? 'Server action completed.' : summaries.join(' · ');
    } catch (_) {
      return 'Decision saved. Device delivery will retry when connected and permitted.';
    }
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start reviewing again?'),
        content: const Text(
          'Clear all review progress for this account on this phone, including Trash review and Undo history. Photos will not be restored or deleted. Device settings and upload exclusions will stay in place.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset review progress')),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _run(() async {
      _checkAccount();
      await _session!.reset();
      _buffer.clear();
      _asset = null;
      _started = false;
      _delivery.refresh(null);
    });
  }

  Widget _setup(bool enabled) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        _trashMode ? 'Restore from server Trash' : 'Choose where Trash applies',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      if (!_managed)
        const Text(
          'This server does not support device selection. Upgrade the server before using selective review. Stock Keep/Trash remains available with its normal sync behavior.',
        ),
      CheckboxListTile(
        value: _trashMode || _serverSelected,
        title: const Text('Server'),
        secondary: const Icon(Icons.cloud_outlined),
        subtitle: Text(_trashMode ? 'Restore the server copy only' : 'Move the server copy to Trash'),
        onChanged: enabled && _managed && !_trashMode ? (v) => setState(() => _serverSelected = v!) : null,
      ),
      ..._devices.map(
        (d) => CheckboxListTile(
          value: !_trashMode && _selectedDevices.contains(d['id']),
          secondary: Icon(d['enabled'] == true ? Icons.phone_android : Icons.phonelink_off),
          title: Text('${d['name']}${d['current'] == true ? ' · this phone' : ''}'),
          subtitle: Text(
            _trashMode
                ? 'Device Trash sources are not supported yet'
                : d['reason'] as String? ??
                      (d['online'] == true
                          ? 'Available · confirmation required on device'
                          : 'Offline · queued until it reconnects'),
          ),
          onChanged: enabled && !_trashMode && d['enabled'] == true
              ? (v) => setState(() {
                  if (v!) {
                    _selectedDevices.add(d['id'] as String);
                  } else {
                    _selectedDevices.remove(d['id']);
                  }
                })
              : null,
        ),
      ),
      if (!_trashMode && _managed)
        ..._devices
            .where((d) => d['legacy'] == true && d['current'] != true)
            .map(
              (d) => TextButton(
                onPressed: enabled ? () => _replaceLegacyDevice(d) : null,
                child: Text('Replace old entry: ${d['name']}'),
              ),
            ),
      if (_trashMode)
        const Text(
          'Only server Trash is available in this version. Device Trash can differ and requires a connected device; those sources remain disabled.',
        ),
      if (!_trashMode && _managed)
        const Text(
          'Unchecked copies stay where they are. A server-deleted photo will not be automatically uploaded again by modified phones. Each device’s deletion settings are respected. After reinstall, old pending phone actions are cancelled and previous local Undo history is unavailable. The official Immich app has separate backup and deletion settings that can also affect these photos.',
        ),
      const SizedBox(height: 16),
      FilledButton.icon(
        icon: const Icon(Icons.play_arrow),
        label: const Text('Start review'),
        onPressed: enabled && (_trashMode || _serverSelected || _selectedDevices.isNotEmpty)
            ? () => _run(() async {
                if (_managed) {
                  await ref.read(reviewDeviceServiceProvider).register();
                  final current = (await ref.read(reviewDeviceServiceProvider).api.call('devices') as List)
                      .map((d) => Map<String, dynamic>.from(d as Map))
                      .toList();
                  _checkAccount();
                  _devices = current;
                  _selectedDevices.removeWhere((id) => !current.any((d) => d['id'] == id && d['enabled'] == true));
                  if (!_trashMode && !_serverSelected && _selectedDevices.isEmpty) {
                    throw StateError('No enabled destination');
                  }
                }
                _started = true;
                await _loadNext(reset: true);
              })
            : null,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final asset = _asset;
    final session = _session;
    ref.watch(currentUserProvider);
    final readOnly = ref.watch(readonlyModeProvider);
    final trashEnabled =
        !readOnly &&
        (_trashMode || (_managed && !_serverSelected) || ref.watch(serverInfoProvider).serverFeatures.trash);
    final accountMatches = _scope == _currentScope;
    final enabled = !_busy && accountMatches;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Gallery Review'),
          actions: [
            IconButton(
              tooltip: 'Start over',
              icon: const Icon(Icons.restart_alt),
              onPressed: enabled && session != null && !session.pending ? _reset : null,
            ),
            IconButton(
              tooltip: 'Review destinations',
              icon: const Icon(Icons.devices),
              onPressed: enabled && session?.pending != true ? () => setState(() => _started = false) : null,
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    Text(
                      _trashMode
                          ? 'Swipe left: Nothing · Swipe right: Restore to server'
                          : 'Swipe left: Trash selected copies · Swipe right: Keep',
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _album ?? '',
                            items: [
                              const DropdownMenuItem(value: '', child: Text('All albums')),
                              DropdownMenuItem(
                                value: '__trash__',
                                enabled: _managed,
                                child: const Text('Trash · server only'),
                              ),
                              ..._albums.map(
                                (a) => DropdownMenuItem(
                                  value: a.id,
                                  child: Text(a.albumName, overflow: TextOverflow.ellipsis),
                                ),
                              ),
                            ],
                            onChanged: enabled && session?.pending != true
                                ? (id) => _run(() async {
                                    await session!.setTrashMode(id == '__trash__');
                                    _album = id == '' ? null : id;
                                    _started = false;
                                    _asset = null;
                                    _buffer.clear();
                                    _delivery.refresh(null);
                                  })
                                : null,
                          ),
                        ),
                        TextButton(
                          onPressed: enabled && session?.pending != true
                              ? () async {
                                  final dates = await showDateRangePicker(
                                    context: context,
                                    firstDate: DateTime(1900),
                                    lastDate: DateTime.now().add(const Duration(days: 1)),
                                    initialDateRange: _dates,
                                  );
                                  if (!mounted || dates == null) {
                                    return;
                                  }
                                  await _run(() async {
                                    _dates = dates;
                                    await _loadNext(reset: true);
                                  });
                                }
                              : null,
                          child: Text(_dates == null ? 'Dates' : 'Change dates'),
                        ),
                        if (_dates != null)
                          IconButton(
                            tooltip: 'Clear date filter',
                            onPressed: enabled && session?.pending != true
                                ? () => _run(() async {
                                    _dates = null;
                                    await _loadNext(reset: true);
                                  })
                                : null,
                            icon: const Icon(Icons.clear),
                          ),
                      ],
                    ),
                    Text('${session?.reviewed.length ?? 0} reviewed · Progress saved on this device'),
                  ],
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (!accountMatches) const Text('Account changed. Close and reopen Review.'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Text(_error!),
                      TextButton(
                        onPressed: enabled
                            ? () {
                                if (_session == null) {
                                  setState(() => _busy = true);
                                  unawaited(_initialize());
                                } else {
                                  unawaited(_run(() => _loadNext(reset: true)));
                                }
                              }
                            : null,
                        child: const Text('Reload'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: !_started && session != null
                    ? _setup(enabled)
                    : asset == null
                    ? Center(
                        child: Text(
                          _busy
                              ? 'Loading…'
                              : _error != null
                              ? 'Review unavailable'
                              : 'All caught up for these filters',
                        ),
                      )
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                            child: Column(
                              children: [
                                Text(asset.originalFileName, maxLines: 2, overflow: TextOverflow.ellipsis),
                                Text(asset.localDateTime.toString().substring(0, 10)),
                              ],
                            ),
                          ),
                          Expanded(
                            child: asset.type == AssetTypeEnum.VIDEO
                                ? ReviewVideo(
                                    key: ValueKey(asset.id),
                                    assetId: asset.id,
                                    mediaWrapper: (media) => _swipeMedia(media, asset.id, enabled, trashEnabled),
                                  )
                                : _swipeMedia(
                                    Image(
                                      key: ValueKey(asset.id),
                                      image: _preview(asset),
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, _, _) => const Center(child: Text('Preview unavailable')),
                                    ),
                                    asset.id,
                                    enabled,
                                    trashEnabled,
                                  ),
                          ),
                        ],
                      ),
              ),
              if (session?.pending == true)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Action confirmation pending. Retry the same action or Undo before continuing.'),
                ),
              if (_deliveryStatus != null) Padding(padding: const EdgeInsets.all(8), child: Text(_deliveryStatus!)),
              if (_started)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: enabled && session?.lastId != null && (!readOnly || session?.lastTrash != true)
                            ? _undo
                            : null,
                        icon: const Icon(Icons.undo),
                        label: const Text('Undo'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: enabled && asset != null && (_trashMode || trashEnabled) && session?.pending != true
                            ? () => _decide(!_trashMode)
                            : session?.pending == true && !_trashMode && enabled
                            ? () => _decide(true)
                            : null,
                        style: _trashMode
                            ? FilledButton.styleFrom(
                                backgroundColor: Colors.grey.shade300,
                                foregroundColor: Colors.black87,
                              )
                            : null,
                        icon: Icon(_trashMode ? Icons.skip_next : Icons.delete_outline),
                        label: Text(_trashMode ? 'Nothing' : 'Trash'),
                      ),
                      FilledButton.icon(
                        onPressed:
                            enabled &&
                                asset != null &&
                                (!_trashMode || trashEnabled) &&
                                (session?.pending != true || _trashMode)
                            ? () => _decide(_trashMode)
                            : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                        ),
                        icon: Icon(_trashMode ? Icons.restore_from_trash : Icons.check),
                        label: Text(_trashMode ? 'Restore' : 'Keep'),
                      ),
                    ],
                  ),
                ),
              if (!trashEnabled) Text(readOnly ? 'Read-only mode is enabled.' : 'Trash is disabled on this server.'),
            ],
          ),
        ),
      ),
    );
  }
}
