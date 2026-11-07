import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Presentation-only swipe feedback; the caller owns decisions and recovery.
class ReviewSwipeCard extends StatefulWidget {
  const ReviewSwipeCard({
    super.key,
    required this.enabled,
    required this.trashEnabled,
    required this.onKeep,
    required this.onTrash,
    required this.child,
  });

  final bool enabled;
  final bool trashEnabled;
  final VoidCallback onKeep;
  final VoidCallback onTrash;
  final Widget child;

  @override
  State<ReviewSwipeCard> createState() => _ReviewSwipeCardState();
}

class _ReviewSwipeCardState extends State<ReviewSwipeCard> {
  static const _threshold = 100.0;
  double _drag = 0;
  bool _dragging = false;

  @override
  void didUpdateWidget(ReviewSwipeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _drag = 0;
      _dragging = false;
    }
  }

  void _reset() => setState(() {
    _drag = 0;
    _dragging = false;
  });

  void _finish() {
    final distance = _drag;
    _reset();
    if (!widget.enabled) {
      return;
    }
    if (distance > _threshold) {
      widget.onKeep();
    } else if (distance < -_threshold && widget.trashEnabled) {
      widget.onTrash();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      // An accepted Flutter drag can end on PointerCancel as well as PointerUp.
      // Clear its distance before the recognizer handles a canceled pointer.
      onPointerCancel: (_) => _reset(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: widget.enabled ? (_) => setState(() => _dragging = true) : null,
        onHorizontalDragUpdate: widget.enabled ? (event) => setState(() => _drag += event.delta.dx) : null,
        onHorizontalDragCancel: _reset,
        onHorizontalDragEnd: widget.enabled ? (_) => _finish() : null,
        child: ClipRect(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: _drag),
            duration: _dragging || MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: widget.child,
            builder: (context, distance, child) {
              final keep = distance >= 0;
              final available = keep || widget.trashEnabled;
              final strength = (distance.abs() / _threshold).clamp(0.0, 1.0);
              final color = available
                  ? keep
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFFC62828)
                  : scheme.outline;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Transform.translate(
                    offset: Offset(distance, 0),
                    child: Transform.rotate(
                      // Only the media moves; feedback stays on the screen edge.
                      angle: (distance / 18).clamp(-10.0, 10.0) * math.pi / 180,
                      child: Padding(padding: const EdgeInsets.all(16), child: child),
                    ),
                  ),
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: keep ? Alignment.centerRight : Alignment.centerLeft,
                          radius: 0.8,
                          colors: [
                            color.withValues(alpha: strength * 0.55),
                            color.withValues(alpha: strength * 0.20),
                            color.withValues(alpha: 0),
                          ],
                          stops: const [0, 0.45, 1],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    left: keep ? null : 16,
                    right: keep ? 16 : null,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: strength,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Text(
                              !available
                                  ? 'Trash unavailable'
                                  : keep
                                  ? 'KEEP →'
                                  : '← TRASH',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
