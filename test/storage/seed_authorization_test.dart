import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/seed_authorization.dart';

void main() {
  test('SeedAuthorization TTL 窗口', () {
    final auth = SeedAuthorization(ttl: const Duration(milliseconds: 50));
    expect(auth.isAuthorized('aaaaaaaaaaaaaaaa'), isFalse);
    auth.authorize('aaaaaaaaaaaaaaaa');
    expect(auth.isAuthorized('aaaaaaaaaaaaaaaa'), isTrue);
    expect(auth.isAuthorized('bbbbbbbbbbbbbbbb'), isFalse);
  });
}
