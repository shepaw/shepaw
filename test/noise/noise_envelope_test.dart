import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/noise/noise_envelope.dart';

void main() {
  group('envelope encode / decode roundtrip', () {
    test('hs frame', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final raw = encodeFrame(Frame(t: FrameType.hs, payload: payload));
      final decoded = decodeFrame(raw);
      expect(decoded.t, FrameType.hs);
      expect(decoded.payload, equals(payload));
    });

    test('data frame with arbitrary bytes', () {
      final payload = Uint8List(256);
      for (var i = 0; i < 256; i++) {
        payload[i] = i;
      }
      final raw = encodeFrame(Frame(t: FrameType.data, payload: payload));
      final decoded = decodeFrame(raw);
      expect(decoded.t, FrameType.data);
      expect(decoded.payload, equals(payload));
    });

    test('err frame with empty payload', () {
      final raw = encodeFrame(Frame(t: FrameType.err, payload: Uint8List(0)));
      final decoded = decodeFrame(raw);
      expect(decoded.t, FrameType.err);
      expect(decoded.payload.length, 0);
    });

    test('emits exactly the expected wire shape', () {
      final raw = encodeFrame(Frame(t: FrameType.hs, payload: Uint8List.fromList([0xde, 0xad])));
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      expect(obj['v'], 2);
      expect(obj['t'], 'hs');
      expect(obj['p'], '3q0'); // base64url of [0xde, 0xad], unpadded
    });
  });

  group('envelope decode — version rejection', () {
    test('rejects v=1', () {
      final raw = jsonEncode({'v': 1, 't': 'hs', 'p': ''});
      expect(() => decodeFrame(raw), throwsEnvelopeError('UNSUPPORTED_VERSION'));
    });
    test('rejects v=3', () {
      final raw = jsonEncode({'v': 3, 't': 'hs', 'p': ''});
      expect(() => decodeFrame(raw), throwsEnvelopeError('UNSUPPORTED_VERSION'));
    });
    test('rejects missing v', () {
      final raw = jsonEncode({'t': 'hs', 'p': ''});
      expect(() => decodeFrame(raw), throwsEnvelopeError('UNSUPPORTED_VERSION'));
    });
    test('rejects v as string "2"', () {
      final raw = jsonEncode({'v': '2', 't': 'hs', 'p': ''});
      expect(() => decodeFrame(raw), throwsEnvelopeError('UNSUPPORTED_VERSION'));
    });
  });

  group('envelope decode — type rejection', () {
    test('rejects unknown t', () {
      final raw = jsonEncode({'v': 2, 't': 'garbage', 'p': ''});
      expect(() => decodeFrame(raw), throwsEnvelopeError('UNSUPPORTED_TYPE'));
    });
    test('rejects missing t', () {
      final raw = jsonEncode({'v': 2, 'p': ''});
      expect(() => decodeFrame(raw), throwsEnvelopeError('UNSUPPORTED_TYPE'));
    });
  });

  group('envelope decode — payload rejection', () {
    test('rejects non-string p', () {
      final raw = jsonEncode({'v': 2, 't': 'hs', 'p': 123});
      expect(() => decodeFrame(raw), throwsEnvelopeError('MALFORMED_FRAME'));
    });
    test('rejects missing p', () {
      final raw = jsonEncode({'v': 2, 't': 'hs'});
      expect(() => decodeFrame(raw), throwsEnvelopeError('MALFORMED_FRAME'));
    });
    test('rejects standard base64 (with + or /)', () {
      final raw = jsonEncode({'v': 2, 't': 'hs', 'p': 'ab+/'});
      expect(() => decodeFrame(raw), throwsEnvelopeError('MALFORMED_FRAME'));
    });
    test('rejects non-base64 garbage', () {
      final raw = jsonEncode({'v': 2, 't': 'hs', 'p': '!!!!'});
      expect(() => decodeFrame(raw), throwsEnvelopeError('MALFORMED_FRAME'));
    });
    test('rejects oversized payload', () {
      final big = Uint8List(2000);
      final raw = encodeFrame(Frame(t: FrameType.data, payload: big));
      expect(() => decodeFrame(raw, maxPayload: 1000), throwsEnvelopeError('FRAME_TOO_LARGE'));
    });
    test('accepts payload exactly at limit', () {
      final payload = Uint8List(1000);
      final raw = encodeFrame(Frame(t: FrameType.data, payload: payload));
      final f = decodeFrame(raw, maxPayload: 1000);
      expect(f.payload.length, 1000);
    });
  });

  group('envelope decode — JSON rejection', () {
    test('rejects non-JSON', () {
      expect(() => decodeFrame('not-json'), throwsEnvelopeError('MALFORMED_FRAME'));
    });
    test('rejects JSON array', () {
      expect(() => decodeFrame('[1,2,3]'), throwsEnvelopeError('MALFORMED_FRAME'));
    });
    test('rejects JSON null', () {
      expect(() => decodeFrame('null'), throwsEnvelopeError('MALFORMED_FRAME'));
    });
  });

  group('base64url helpers', () {
    test('empty roundtrip', () {
      expect(fromBase64Url(toBase64Url(<int>[])).length, 0);
    });

    test('256 byte roundtrip', () {
      final bytes = Uint8List(256);
      for (var i = 0; i < 256; i++) {
        bytes[i] = i;
      }
      expect(fromBase64Url(toBase64Url(bytes)), equals(bytes));
    });

    test('encodes without padding', () {
      // 1 byte → padded "AA==", unpadded "AA"
      expect(toBase64Url([0]), 'AA');
    });

    test('decodes with padding too (tolerance for other encoders)', () {
      expect(fromBase64Url('AA=='), equals([0]));
    });
  });

  group('cross-language fixture', () {
    test('base64url of [0xde, 0xad] is "3q0" (matches TS)', () {
      // This exact fixture is asserted by the TS side's envelope.test.ts.
      expect(toBase64Url([0xde, 0xad]), '3q0');
    });
  });
}

// ── Matcher helpers ───────────────────────────────────────────────────────

Matcher throwsEnvelopeError(String code) => throwsA(
      isA<EnvelopeError>().having((e) => e.code, 'code', code),
    );
