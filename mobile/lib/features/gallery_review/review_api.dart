import 'dart:convert';

import 'package:immich_mobile/services/api.service.dart';
import 'package:openapi/api.dart';

/// Versioned fork protocol. Uses the same authenticated transport as stock APIs.
class ReviewApi {
  ReviewApi(this.api);
  final ApiService api;
  bool supportsDeviceIdentity = false;

  Future<dynamic> call(String path, {Object? body}) async {
    final response = await api.apiClient.invokeAPI(
      '/gallery-review/$path',
      body == null ? 'GET' : 'POST',
      [],
      body,
      {},
      {},
      'application/json',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
    return jsonDecode(response.body);
  }

  Future<bool> available() async {
    try {
      final result = await call('capabilities');
      supportsDeviceIdentity = result['deviceIdentity'] == 1;
      if (result['protocol'] != 1) {
        throw StateError('Unsupported Gallery Review protocol');
      }
      return true;
    } on ApiException catch (error) {
      if (error.code == 404) {
        return false;
      }
      rethrow;
    }
  }
}
