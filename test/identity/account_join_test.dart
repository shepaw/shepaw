import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/identity_export_bundle.dart';
import 'package:shepaw/identity/services/ownership_service.dart';

void main() {
  group('Account join protocol', () {
    test('join request payload fields are documented in export bundle', () {
      const bundle = IdentityExportBundle(
        userRecord: 'user',
        petRecord: 'pet',
        exportedAtMs: 1000,
        signatureBase64: 'sig',
      );
      expect(bundle.signedPayload, contains('1000'));
    });

    test('OwnershipService bondPayload stable for legacy tests', () {
      expect(
        OwnershipService.bondPayload(userId: 'a', petId: 'b', timestampMs: 1),
        'shepaw:ownership:v1:a:b:1',
      );
    });
  });
}
