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
  test('reset clears both review sources without media operations', () async {
    String? disk;
    final session = ReviewSession(
      save: (s) async => disk = s,
      trash: (_) async => fail('Unexpected trash'),
      restore: (_) async => fail('Unexpected restore'),
    );
    await session.decide('normal', toTrash: false);
    await session.setTrashMode(true);
    await session.decide('trashed', toTrash: false);
    await session.reset();
    expect(session.reviewed, isEmpty);
    expect(session.lastId, isNull);
    await session.setTrashMode(false);
    expect(session.reviewed, isEmpty);
    expect(disk, isNotNull);
  });
  test('failed reset preserves progress and Undo', () async {
    var failWrite = false;
    final session = ReviewSession(
      save: (_) async {
        if (failWrite) {
          throw Exception('disk full');
        }
      },
      trash: (_) async {},
      restore: (_) async {},
    );
    await session.decide('photo', toTrash: false);
    failWrite = true;
    await expectLater(session.reset(), throwsException);
    expect(session.reviewed, {'photo'});
    expect(session.lastId, 'photo');
  });
  test('pending retry retains operation ID and original destinations across restart', () async {
    String? disk;
    Map<String, dynamic>? sent;
    final session = ReviewSession(
      save: (s) async => disk = s,
      trash: (_) async {},
      restore: (_) async {},
      applyOperation: (op) async {
        sent = op;
        throw Exception('timeout');
      },
    );
    await expectLater(
      session.decide(
        'photo',
        toTrash: true,
        destinations: {
          'server': false,
          'devices': ['phone'],
        },
      ),
      throwsException,
    );
    await expectLater(session.reset(), throwsStateError);
    await expectLater(session.setTrashMode(true), throwsStateError);
    final recovered = ReviewSession(
      saved: disk,
      save: (s) async => disk = s,
      trash: (_) async {},
      restore: (_) async {},
      applyOperation: (op) async => expect(op, sent),
    );
    await recovered.decide('photo', toTrash: true, destinations: {'server': true, 'devices': []});
    expect(recovered.pending, isFalse);
  });
  test('failed Keep write preserves previous operation for Undo', () async {
    var failWrite = false;
    String? undone;
    final session = ReviewSession(
      save: (_) async {
        if (failWrite) {
          throw Exception('disk full');
        }
      },
      trash: (_) async {},
      restore: (_) async => fail('legacy restore'),
      applyOperation: (_) async {},
      undoOperation: (id) async => undone = id,
    );
    await session.decide('photo', toTrash: true, destinations: {'server': true, 'devices': []});
    final id = session.operation!['operationId'];
    failWrite = true;
    await expectLater(session.decide('next', toTrash: false), throwsException);
    failWrite = false;
    await session.undo();
    expect(undone, id);
  });
  test('Trash review sends restore and keeps independent progress', () async {
    Map<String, dynamic>? sent;
    final session = ReviewSession(
      save: (_) async {},
      trash: (_) async {},
      restore: (_) async {},
      applyOperation: (op) async => sent = op,
    );
    await session.decide('photo', toTrash: false);
    await session.setTrashMode(true);
    expect(session.reviewed, isEmpty);
    await session.decide('photo', toTrash: true, destinations: {'server': true, 'devices': []});
    expect(sent!['action'], 'restore');
    await session.setTrashMode(false);
    expect(session.reviewed, {'photo'});
  });
}
