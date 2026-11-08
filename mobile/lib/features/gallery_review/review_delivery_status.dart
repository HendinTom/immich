import 'dart:async';

/// Device delivery is independent of an already journaled/server-accepted
/// decision. Late responses must not replace feedback for a newer decision.
class ReviewDeliveryStatus {
  ReviewDeliveryStatus({required this.load, required this.publish});

  final Future<String> Function(String operationId) load;
  final void Function(String?) publish;
  int _generation = 0;
  bool _disposed = false;

  void refresh(String? operationId) {
    if (_disposed) {
      return;
    }
    final generation = ++_generation;
    publish(operationId == null ? null : 'Decision saved. Checking device delivery…');
    if (operationId != null) {
      unawaited(_refresh(operationId, generation));
    }
  }

  Future<void> _refresh(String id, int generation) async {
    String status;
    try {
      status = await load(id);
    } catch (_) {
      status = 'Decision saved. Device delivery will retry when connected and permitted.';
    }
    if (!_disposed && generation == _generation) {
      publish(status);
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
  }
}
