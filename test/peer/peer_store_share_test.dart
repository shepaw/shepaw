import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/peer_store_share.dart';

void main() {
  group('PeerStoreShareAllowlist', () {
    test('整区允许任意 path', () {
      final a = PeerStoreShareAllowlist.fromEntries(const [
        PeerStoreShareEntry(space: 'files'),
      ]);
      expect(a.allows('files', null), isTrue);
      expect(a.allows('files', ''), isTrue);
      expect(a.allows('files', 'docs/a.txt'), isTrue);
      expect(a.allows('artifacts', 'x'), isFalse);
    });

    test('path 前缀命中与未命中', () {
      final a = PeerStoreShareAllowlist.fromEntries(const [
        PeerStoreShareEntry(space: 'files', path: 'docs'),
        PeerStoreShareEntry(space: 'files', path: 'photos'),
      ]);
      expect(a.allows('files', ''), isTrue); // 根 list
      expect(a.allows('files', 'docs'), isTrue);
      expect(a.allows('files', 'docs/a.txt'), isTrue);
      expect(a.allows('files', 'photos/b.jpg'), isTrue);
      expect(a.allows('files', 'secret/x'), isFalse);
      expect(a.allowsListedPath('files', 'docs/__folder__'), isTrue);
      expect(a.allowsListedPath('files', 'secret/x'), isFalse);
      expect(a.allowsListedPath('files', 'docs'), isTrue);
    });

    test('ownerDefaults', () {
      final a = PeerStoreShareAllowlist.ownerDefaults();
      expect(a.isWholeSpace('files'), isTrue);
      expect(a.isWholeSpace('artifacts'), isTrue);
      expect(a.isWholeSpace('workspaces'), isTrue);
      expect(a.isWholeSpace('public'), isTrue);
      expect(a.allows('attachments', 'x'), isFalse);
      expect(a.isEmpty, isFalse);
    });
  });
}
