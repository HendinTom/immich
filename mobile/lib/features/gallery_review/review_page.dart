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
  List<AlbumResponseDto> _albums = [];
  String? _album;
  DateTimeRange? _dates;
  String? _error;
  String? _scope;
  bool _busy = true;

  String get _currentScope => '${settings.Store.get(StoreKey.serverEndpoint)}|${ref.read(currentUserProvider)?.id}';
  void _checkAccount() {
    if (_scope != _currentScope || ref.read(currentUserProvider) == null) {
      throw StateError('Account changed. Reopen Review.');
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      _scope = _currentScope;
      _checkAccount();
      final folder = await getApplicationSupportDirectory();
      final key = sha256.convert(utf8.encode(_scope!));
      final file = File('${folder.path}/gallery-review-$key.json');
      _session = ReviewSession(
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
      await _loadNext();
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
      if (item != null && item.ownerId == userId) {
        _asset = item;
        return;
      }
    }
    while (_buffer.isNotEmpty) {
      final item = _buffer.removeAt(0);
      if (!_session!.reviewed.contains(item.id)) {
        _asset = item;
        return;
      }
    }
    // Consume a page locally, then restart search when refilling. Deletions
    // cannot shift a retained page offset and skip an unreviewed item.
    var page = 1;
    while (true) {
      final result = await api.searchApi.searchAssets(
        MetadataSearchDto(
          albumIds: Optional.present(_album == null ? [] : [_album!]),
          page: Optional.present(page),
          size: const Optional.present(250),
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
          withDeleted: const Optional.present(false),
        ),
      );
      _checkAccount();
      if (result == null) {
        throw StateError('No search response');
      }
      for (final item in result.assets.items) {
        if (item.ownerId == userId && !item.isTrashed && !_session!.reviewed.contains(item.id)) {
          _buffer.add(item);
        }
      }
      if (_buffer.isNotEmpty) {
        _asset = _buffer.removeAt(0);
        return;
      }
      if (result.assets.nextPage == null) {
        _asset = null;
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
      await _session!.decide(asset.id, toTrash: trash);
      _asset = null;
      await _loadNext();
    });
  }

  Future<void> _undo() async {
    await _run(() async {
      final id = _session!.lastId;
      await _session!.undo();
      await _loadNext(preferredId: id);
    });
  }

  Widget _swipeMedia(Widget media, String assetId, bool enabled, bool trashEnabled) => ReviewSwipeCard(
    key: ValueKey(assetId),
    enabled: enabled && _session?.pending != true,
    trashEnabled: trashEnabled,
    onKeep: () => unawaited(_decide(false)),
    onTrash: () => unawaited(_decide(true)),
    child: media,
  );

  @override
  Widget build(BuildContext context) {
    final asset = _asset;
    final session = _session;
    ref.watch(currentUserProvider);
    final readOnly = ref.watch(readonlyModeProvider);
    final trashEnabled = ref.watch(serverInfoProvider).serverFeatures.trash && !readOnly;
    final accountMatches = _scope == _currentScope;
    final enabled = !_busy && accountMatches;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Gallery Review')),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    const Text(
                      'Swipe right to Keep, left to Trash. Device copies follow each device’s Immich sync settings.',
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _album ?? '',
                            items: [
                              const DropdownMenuItem(value: '', child: Text('All albums')),
                              ..._albums.map(
                                (a) => DropdownMenuItem(
                                  value: a.id,
                                  child: Text(a.albumName, overflow: TextOverflow.ellipsis),
                                ),
                              ),
                            ],
                            onChanged: enabled && session?.pending != true
                                ? (id) => _run(() async {
                                    _album = id == '' ? null : id;
                                    await _loadNext(reset: true);
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
                child: asset == null
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
                                      image: RemoteImageProvider(
                                        url: getThumbnailUrlForRemoteId(asset.id, type: AssetMediaSize.preview),
                                      ),
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
                  child: Text('Trash confirmation pending. Retry Trash or Undo before continuing.'),
                ),
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
                      onPressed: enabled && asset != null && trashEnabled ? () => _decide(true) : null,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Trash'),
                    ),
                    FilledButton.icon(
                      onPressed: enabled && asset != null && session?.pending != true ? () => _decide(false) : null,
                      icon: const Icon(Icons.check),
                      label: const Text('Keep'),
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
