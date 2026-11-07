import 'dart:async';
import 'package:flutter/material.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:native_video_player/native_video_player.dart';

class ReviewVideo extends StatefulWidget {
  const ReviewVideo({super.key, required this.assetId, this.mediaWrapper});
  final String assetId;
  final Widget Function(Widget media)? mediaWrapper;
  @override
  State<ReviewVideo> createState() => _ReviewVideoState();
}

class _ReviewVideoState extends State<ReviewVideo> with WidgetsBindingObserver {
  NativeVideoPlayerController? _controller;
  String? _error;
  bool _ready = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.onPlaybackReady.removeListener(_onReady);
    unawaited(_pause());
    super.dispose();
  }

  Future<void> _pause() async {
    try {
      await _controller?.pause();
    } catch (_) {
      /* The platform view may already be disposed. */
    }
  }

  void _onReady() {
    if (mounted) {
      setState(() => _ready = true);
    }
  }

  Future<void> _play() async {
    try {
      await _controller?.play();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Video could not be played');
      }
    }
  }

  Future<void> _load(NativeVideoPlayerController controller) async {
    _controller = controller;
    controller.onPlaybackReady.addListener(_onReady);
    try {
      final source = await VideoSource.init(
        path: getPlaybackUrlForRemoteId(widget.assetId),
        type: VideoSourceType.network,
        headers: ApiService.getRequestHeaders(),
      );
      if (!mounted) {
        return;
      }
      await controller.loadVideoSource(source);
      await controller.setVolume(1);
      if (mounted) {
        setState(() => _ready = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Video unavailable');
      }
    }
  }

  Widget _media() {
    final media = Center(
      child: AspectRatio(
        aspectRatio: _controller?.videoInfo?.aspectRatio ?? 4 / 3,
        child: NativeVideoPlayerView(onViewReady: _load),
      ),
    );
    return widget.mediaWrapper?.call(media) ?? media;
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(child: _media()),
      if (_error != null) Text(_error!),
      if (_controller != null)
        ValueListenableBuilder<int>(
          valueListenable: _controller!.onPlaybackPositionChanged,
          builder: (_, position, _) {
            final duration = _controller!.videoInfo?.duration ?? 0;
            return Slider(
              value: position.toDouble().clamp(0, duration.toDouble()),
              max: duration > 0 ? duration.toDouble() : 1,
              onChanged: _ready && duration > 0 ? (value) => _controller!.seekTo(value.toInt()) : null,
            );
          },
        ),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(tooltip: 'Play video', onPressed: _ready ? _play : null, icon: const Icon(Icons.play_arrow)),
          IconButton(tooltip: 'Pause video', onPressed: _ready ? _pause : null, icon: const Icon(Icons.pause)),
        ],
      ),
    ],
  );
}
