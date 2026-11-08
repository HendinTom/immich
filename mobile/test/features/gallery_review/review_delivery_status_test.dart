import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/features/gallery_review/review_delivery_status.dart';

void main() {
  test('slow delivery does not block navigation and Keep starts no sync', () async {
    final pending = Completer<String>();
    final calls = <String>[];
    final updates = <String?>[];
    final tracker = ReviewDeliveryStatus(
      load: (id) {
        calls.add(id);
        return pending.future;
      },
      publish: updates.add,
    );
    tracker.refresh('trash');
    expect(pending.isCompleted, isFalse);
    expect(updates.last, contains('Checking device delivery'));
    tracker.refresh(null); // Keep/Nothing clears feedback, without starting sync.
    expect(calls, ['trash']);
    pending.complete('1 device updated');
    await Future<void>.delayed(Duration.zero);
    expect(updates.last, isNull);
  });

  test('late original action cannot overwrite newer Undo status', () async {
    final old = Completer<String>();
    final undo = Completer<String>();
    var calls = 0;
    final updates = <String?>[];
    final tracker = ReviewDeliveryStatus(load: (_) => calls++ == 0 ? old.future : undo.future, publish: updates.add);
    tracker.refresh('same-operation');
    tracker.refresh('same-operation');
    undo.complete('restored');
    await Future<void>.delayed(Duration.zero);
    old.complete('trashed');
    await Future<void>.delayed(Duration.zero);
    expect(updates.last, 'restored');
  });

  test('errors remain pending instead of reporting success', () async {
    final updates = <String?>[];
    final tracker = ReviewDeliveryStatus(load: (_) async => throw StateError('offline'), publish: updates.add);
    tracker.refresh('operation');
    await Future<void>.delayed(Duration.zero);
    expect(updates.last, contains('retry'));
  });

  test('leaving Review suppresses completion callbacks', () async {
    final pending = Completer<String>();
    final updates = <String?>[];
    final tracker = ReviewDeliveryStatus(load: (_) => pending.future, publish: updates.add);
    tracker.refresh('operation');
    tracker.dispose();
    final count = updates.length;
    pending.complete('updated');
    await Future<void>.delayed(Duration.zero);
    expect(updates.length, count);
  });
}
