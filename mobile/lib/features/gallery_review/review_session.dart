import 'dart:convert';
import 'package:uuid/uuid.dart';

/// Account-scoped review journal. A pending trash is saved before contacting the
/// server, so a timeout or process exit never discards the recovery action.
class ReviewSession {
  ReviewSession({
    required this.save,
    required this.trash,
    required this.restore,
    String? saved,
    this.applyOperation,
    this.undoOperation,
  }) {
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      _normal.addAll((data['reviewed'] as List).cast<String>());
      _trash.addAll((data['trashReviewed'] as List? ?? []).cast<String>());
      trashMode = data['trashMode'] as bool? ?? false;
      operation = data['operation'] == null ? null : Map<String, dynamic>.from(data['operation'] as Map);
      lastId = data['lastId'] as String?;
      lastTrash = data['lastTrash'] as bool? ?? false;
      pending = data['pending'] as bool? ?? false;
    }
  }

  final Future<void> Function(String) save;
  final Future<void> Function(String) trash;
  final Future<void> Function(String) restore;
  final Future<void> Function(Map<String, dynamic>)? applyOperation;
  final Future<void> Function(String)? undoOperation;
  final Set<String> _normal = {};
  final Set<String> _trash = {};
  Set<String> get reviewed => trashMode ? _trash : _normal;
  bool trashMode = false;
  Map<String, dynamic>? operation;
  String? lastId;
  bool lastTrash = false;
  bool pending = false;
  bool busy = false;

  String _encode(Set<String> ids, String? id, bool trashed, bool uncertain) => jsonEncode({
    'reviewed': (trashMode ? _normal : ids).toList(),
    'trashReviewed': (trashMode ? ids : _trash).toList(),
    'trashMode': trashMode,
    'operation': operation,
    'lastId': id,
    'lastTrash': trashed,
    'pending': uncertain,
  });

  Future<void> decide(String id, {required bool toTrash, Map<String, dynamic>? destinations}) async {
    if (busy) {
      return;
    }
    if (pending && (id != lastId || !toTrash)) {
      throw StateError('Resolve the pending trash first');
    }
    busy = true;
    final previousOperation = operation;
    var journalWritten = false;
    try {
      if (toTrash) {
        if (applyOperation != null && !pending) {
          operation = {
            'operationId': const Uuid().v4(),
            'assetId': id,
            'action': trashMode ? 'restore' : 'trash',
            ...?destinations,
          };
        }
        await save(_encode(reviewed, id, true, true));
        journalWritten = true;
        lastId = id;
        lastTrash = true;
        pending = true;
        if (operation != null && applyOperation != null) {
          await applyOperation!(operation!);
        } else {
          await trash(id);
        }
      }
      if (!toTrash) {
        operation = null;
      }
      final next = {...reviewed, id};
      await save(_encode(next, id, toTrash, false));
      reviewed.add(id);
      lastId = id;
      lastTrash = toTrash;
      pending = false;
    } catch (_) {
      if (!journalWritten) {
        operation = previousOperation;
      }
      rethrow;
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
        if (operation != null && undoOperation != null) {
          await undoOperation!(operation!['operationId'] as String);
        } else {
          await restore(id);
        }
      }
      final savedOperation = operation;
      operation = null;
      final next = {...reviewed}..remove(id);
      try {
        await save(_encode(next, null, false, false));
      } catch (_) {
        operation = savedOperation;
        rethrow;
      }
      reviewed.remove(id);
      lastId = null;
      lastTrash = false;
      pending = false;
    } finally {
      busy = false;
    }
  }

  Future<void> setTrashMode(bool value) async {
    if (busy || pending) {
      throw StateError('Resolve the pending action before changing sources');
    }
    final previous = trashMode;
    final previousOperation = operation;
    trashMode = value;
    operation = null;
    try {
      await save(_encode(reviewed, null, false, false));
    } catch (_) {
      trashMode = previous;
      operation = previousOperation;
      rethrow;
    }
    lastId = null;
    lastTrash = false;
  }

  Future<void> reset() async {
    if (busy || pending) {
      throw StateError('Resolve the pending action before resetting');
    }
    // Save first; failed storage must not erase in-memory progress.
    await save(
      jsonEncode({
        'reviewed': [],
        'trashReviewed': [],
        'trashMode': trashMode,
        'lastId': null,
        'lastTrash': false,
        'pending': false,
        'operation': null,
      }),
    );
    _normal.clear();
    _trash.clear();
    lastId = null;
    lastTrash = false;
    operation = null;
  }
}
