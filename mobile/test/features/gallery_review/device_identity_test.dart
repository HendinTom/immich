import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/features/gallery_review/device_identity.dart';

void main() {
  test('installation survives reopen/update but changes when private data is removed', () {
    final directory = Directory.systemTemp.createTempSync('gallery-identity-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/identity.sqlite';
    final before = loadInstallationId(path);
    expect(loadInstallationId(path), before);
    File(path).deleteSync();
    expect(loadInstallationId(path), isNot(before));
  });
  test('device identity is stable and scoped to package and account', () {
    final key = reviewDeviceIdentity('phone-a', 'modified', 'account-a');
    expect(key, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(reviewDeviceIdentity('phone-a', 'modified', 'account-a'), key);
    expect(reviewDeviceIdentity('phone-b', 'modified', 'account-a'), isNot(key));
    expect(reviewDeviceIdentity('phone-a', 'official', 'account-a'), isNot(key));
    expect(reviewDeviceIdentity('phone-a', 'modified', 'account-b'), isNot(key));
  });
}
