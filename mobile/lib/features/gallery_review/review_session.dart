import 'dart:convert';

/// Account-scoped review journal. A pending trash is saved before contacting the
/// server, so a timeout or process exit never discards the recovery action.
class ReviewSession {
  ReviewSession({required this.save, required this.trash, required this.restore, String? saved}) {
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      reviewed.addAll((data['reviewed'] as List).cast<String>());
      lastId = data['lastId'] as String?;
      lastTrash = data['lastTrash'] as bool? ?? false;
      pending = data['pending'] as bool? ?? false;
    }
  }

  final Future<void> Function(String) save;
  final Future<void> Function(String) trash;
  final Future<void> Function(String) restore;
  final Set<String> reviewed = {};
  String? lastId;
  bool lastTrash = false;
  bool pending = false;
  bool busy = false;

  String _encode(Set<String> ids, String? id, bool trashed, bool uncertain) =>
      jsonEncode({'reviewed': ids.toList(), 'lastId': id, 'lastTrash': trashed, 'pending': uncertain});

  Future<void> decide(String id, {required bool toTrash}) async {
    if (busy) {
      return;
    }
    if (pending && (id != lastId || !toTrash)) {
      throw StateError('Resolve the pending trash first');
    }
    busy = true;
    try {
      if (toTrash) {
        await save(_encode(reviewed, id, true, true));
        lastId = id;
        lastTrash = true;
        pending = true;
        await trash(id);
      }
      final next = {...reviewed, id};
      await save(_encode(next, id, toTrash, false));
      reviewed.add(id);
      lastId = id;
      lastTrash = toTrash;
      pending = false;
    } finally {
      busy = false;
    }
  }

  Future<void> undo() async {
    if (busy || lastId == null) {
      return;
    }
    busy = true;
    try {
      final id = lastId!;
      if (lastTrash) {
        await restore(id);
      }
      final next = {...reviewed}..remove(id);
      await save(_encode(next, null, false, false));
      reviewed.remove(id);
      lastId = null;
      lastTrash = false;
      pending = false;
    } finally {
      busy = false;
    }
  }
}
