/// Unit tests for the `shepaw://pair?url=&code=` deep-link parser.
///
/// Covered: valid parse, round-trip via `buildPairDeeplink`, rejection of
/// every malformed shape we could think of. Pure Dart — runs without any
/// Flutter plumbing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/pair_deeplink.dart';

void main() {
  group('parsePairDeeplink — valid inputs', () {
    test('parses a minimal well-formed deep-link', () {
      final raw =
          'shepaw://pair?url=ws%3A%2F%2F127.0.0.1%3A8090%2Facp%2Fws%3FagentId%3Dacp_agent_a1b2c3d4%23fp%3Da1b2c3d4e5f6a7b8&code=4B79KXM2P';
      final parsed = parsePairDeeplink(raw);
      expect(
        parsed.wsUrl,
        'ws://127.0.0.1:8090/acp/ws?agentId=acp_agent_a1b2c3d4#fp=a1b2c3d4e5f6a7b8',
      );
      expect(parsed.code, '4B79KXM2P');
    });

    test('parses wss URLs (production tunnel case)', () {
      final raw =
          'shepaw://pair?url=wss%3A%2F%2Fchannel.shepaw.com%2Fc%2Fmy-agent%2Facp%2Fws%3FagentId%3Dacp_agent_abc%23fp%3Daabbccddeeff0011&code=ABC-DEF-GHJ';
      final parsed = parsePairDeeplink(raw);
      expect(parsed.wsUrl.startsWith('wss://'), isTrue);
      expect(parsed.code, 'ABC-DEF-GHJ');
    });

    test('strips leading/trailing whitespace on the raw payload', () {
      final raw =
          '   shepaw://pair?url=ws%3A%2F%2Flocalhost%3A8090%2Facp%2Fws&code=XYZ12ABCD   \n';
      expect(() => parsePairDeeplink(raw), returnsNormally);
    });

    test('round-trips via buildPairDeeplink', () {
      final original = 'wss://channel.example.com/c/x/acp/ws?agentId=acp_agent_1#fp=0123456789abcdef';
      final code = '4B79KXM2P';
      final link = buildPairDeeplink(wsUrl: original, code: code);
      final parsed = parsePairDeeplink(link);
      expect(parsed.wsUrl, original);
      expect(parsed.code, code);
    });
  });

  group('parsePairDeeplink — rejections', () {
    test('rejects empty input', () {
      expect(
        () => parsePairDeeplink(''),
        throwsA(isA<PairDeeplinkError>()),
      );
      expect(
        () => parsePairDeeplink('   '),
        throwsA(isA<PairDeeplinkError>()),
      );
    });

    test('rejects non-shepaw scheme', () {
      for (final raw in [
        'https://pair?url=ws%3A%2F%2Fx&code=ABC',
        'paw://pair?url=ws%3A%2F%2Fx&code=ABC',
        'SHEPAW1://pair?url=ws%3A%2F%2Fx&code=ABC',
      ]) {
        expect(
          () => parsePairDeeplink(raw),
          throwsA(isA<PairDeeplinkError>()),
          reason: 'should reject $raw',
        );
      }
    });

    test('rejects wrong host', () {
      expect(
        () => parsePairDeeplink('shepaw://connect?url=ws%3A%2F%2Fx&code=ABC'),
        throwsA(isA<PairDeeplinkError>()),
      );
    });

    test('rejects missing url param', () {
      expect(
        () => parsePairDeeplink('shepaw://pair?code=ABC'),
        throwsA(isA<PairDeeplinkError>()),
      );
    });

    test('rejects missing code param', () {
      expect(
        () => parsePairDeeplink('shepaw://pair?url=ws%3A%2F%2Fx'),
        throwsA(isA<PairDeeplinkError>()),
      );
    });

    test('rejects empty url / code values', () {
      expect(
        () => parsePairDeeplink('shepaw://pair?url=&code=ABC'),
        throwsA(isA<PairDeeplinkError>()),
      );
      expect(
        () => parsePairDeeplink('shepaw://pair?url=ws%3A%2F%2Fx&code='),
        throwsA(isA<PairDeeplinkError>()),
      );
    });

    test('rejects http:// inside url param (we require ws:// or wss://)', () {
      expect(
        () => parsePairDeeplink(
          'shepaw://pair?url=http%3A%2F%2Fx&code=ABC',
        ),
        throwsA(isA<PairDeeplinkError>()),
      );
    });

    test('rejects excessively long code (potential padding attack)', () {
      final longCode = 'A' * 100;
      expect(
        () => parsePairDeeplink(
          'shepaw://pair?url=ws%3A%2F%2Fx&code=$longCode',
        ),
        throwsA(isA<PairDeeplinkError>()),
      );
    });

    test('error messages include helpful guidance, not internals', () {
      try {
        parsePairDeeplink('https://pair?url=X&code=Y');
        fail('expected PairDeeplinkError');
      } on PairDeeplinkError catch (e) {
        expect(e.message, isNotEmpty);
        expect(e.message.toLowerCase(), contains('shepaw'));
      }
    });
  });

  group('buildPairDeeplink', () {
    test('URL-encodes both url and code', () {
      final link = buildPairDeeplink(
        wsUrl: 'wss://host/c/x/acp/ws?q=1&r=2',
        code: 'A B',
      );
      // The Uri builder percent-encodes the inner ?, &, space.
      expect(link, contains('url=wss'));
      expect(link, contains('code=A'));
      // Scheme stays as emitted.
      expect(link.startsWith('shepaw://pair?'), isTrue);
    });

    test('accepts display-form codes with hyphens', () {
      final link = buildPairDeeplink(
        wsUrl: 'wss://x/acp/ws',
        code: 'ABC-DEF-GHJ',
      );
      final parsed = parsePairDeeplink(link);
      // Hyphens survive the round trip — the server's normalizer strips
      // them before comparing against the minted token.
      expect(parsed.code, 'ABC-DEF-GHJ');
    });
  });
}
