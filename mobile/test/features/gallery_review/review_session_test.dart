import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/features/gallery_review/review_session.dart';

void main() {
  test('timeout retains recovery journal and never marks the card reviewed', () async {
    String? disk;
    final session = ReviewSession(
      save: (s) async {
        disk = s;
      },
      trash: (_) async {
        throw Exception('timeout');
      },
      restore: (_) async {},
    );
    await expectLater(session.decide('photo', toTrash: true), throwsException);
    expect(session.reviewed, isEmpty);
    final restored = <String>[];
    final restarted = ReviewSession(
      saved: disk,
      save: (s) async {
        disk = s;
      },
      trash: (_) async {},
      restore: (id) async {
        restored.add(id);
      },
    );
    expect(restarted.pending, isTrue);
    await restarted.undo();
    expect(restored, ['photo']);
    expect(restarted.lastId, isNull);
  });
  test('failed journal write prevents remote deletion', () async {
    var calls = 0;
    final session = ReviewSession(
      save: (_) async {
        throw Exception('disk full');
      },
      trash: (_) async {
        calls++;
      },
      restore: (_) async {},
    );
    await expectLater(session.decide('photo', toTrash: true), throwsException);
    expect(calls, 0);
    expect(session.reviewed, isEmpty);
  });
  test('Keep persists across restart and Undo never deletes or restores it', () async {
    String? disk;
    final session = ReviewSession(
      save: (s) async {
        disk = s;
      },
      trash: (_) async {
        fail('unexpected deletion');
      },
      restore: (_) async {
        fail('unexpected restore');
      },
    );
    await session.decide('video', toTrash: false);
    final restarted = ReviewSession(
      saved: disk,
      save: (s) async {
        disk = s;
      },
      trash: (_) async {},
      restore: (_) async {
        fail('unexpected restore');
      },
    );
    expect(restarted.reviewed, {'video'});
    await restarted.undo();
    expect(restarted.reviewed, isEmpty);
  });
  test('failed restore retains Undo for retry', () async {
    final session = ReviewSession(
      save: (_) async {},
      trash: (_) async {},
      restore: (_) async {
        throw Exception('offline');
      },
    );
    await session.decide('photo', toTrash: true);
    await expectLater(session.undo(), throwsException);
    expect(session.lastId, 'photo');
    expect(session.reviewed, {'photo'});
  });
}
