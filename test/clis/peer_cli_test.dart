import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/peer/accept_command.dart';
import 'package:shepaw/clis/shepaw/peer/list_command.dart';
import 'package:shepaw/clis/shepaw/peer/offer_command.dart';
import 'package:shepaw/clis/shepaw/peer/pair_command.dart';
import 'package:shepaw/clis/shepaw/peer/peer_namespace.dart';
import 'package:shepaw/clis/shepaw/peer/reject_command.dart';
import 'package:shepaw/clis/shepaw/peer/status_command.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  group('peer namespace', () {
    test('registered and exposes all commands', () async {
      final help = await PeerNamespace.instance.getHelpAsync();
      final commands = help['commands'] as Map<String, dynamic>;
      for (final name in [
        'pair',
        'offer',
        'status',
        'accept',
        'reject',
        'list',
      ]) {
        expect(commands.containsKey(name), true, reason: 'missing $name');
      }
    });
  });

  group('peer pair', () {
    test('missing link returns error', () async {
      final result = await PeerPairCommand().execute({});
      expect(result['error'], contains('--link'));
    });

    test('invalid link returns error', () async {
      final result =
          await PeerPairCommand().execute({'link': 'not-a-valid-link'});
      expect(result['error'], isNotNull);
    });

    test('shepaw://pair agent link is rejected with guidance', () async {
      final result = await PeerPairCommand().execute({
        'link':
            'shepaw://pair?url=wss%3A%2F%2Fexample.com%2Facp%2Fws&code=ABC-DEF-GHI',
      });
      expect(result['error'], contains('shepaw://pair'));
      expect(result['error'], contains('Add Agent'));
    });
  });

  group('peer list', () {
    test('returns count and peers array', () async {
      final result = await PeerListCommand().execute({});
      expect(result['count'], isA<int>());
      expect(result['peers'], isA<List<dynamic>>());
    });
  });

  group('peer status', () {
    test('returns state when idle', () async {
      final result = await PeerStatusCommand().execute({});
      expect(result['state'], isA<String>());
      expect(result['pending_inbound_request'], isNull);
    });
  });

  group('peer accept', () {
    test('without pending request returns error', () async {
      final result = await PeerAcceptCommand().execute({});
      expect(result['success'], false);
      expect(result['error'], contains('No pending'));
    });
  });

  group('peer reject', () {
    test('without pending request returns error', () async {
      final result = await PeerRejectCommand().execute({});
      expect(result['success'], false);
      expect(result['error'], contains('No pending'));
    });
  });

  group('peer offer', () {
    test('starts session or reports unavailable services', () async {
      final result = await PeerOfferCommand().execute({});
      if (result['success'] == true) {
        expect(result['qr_link'], startsWith('shepaw://peer?'));
        expect(result['pairing_code'], isNotEmpty);
      } else {
        expect(result['error'], isNotNull);
      }
    });
  });
}
