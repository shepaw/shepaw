import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/update_model.dart';
import 'package:shepaw/services/update_checksum.dart';
import 'package:shepaw/services/update_service.dart';

void main() {
  group('UpdateService.resolveCheckUri', () {
    test('substitutes platform and appends version query', () {
      final uri = UpdateService.resolveCheckUri(
        baseUrl: 'https://release.shepaw.com',
        endpoint: '/api/v1/latest-{platform}.json',
        platform: 'macos',
        currentVersion: '1.0.22',
        buildNumber: '1',
      );

      expect(uri.origin, 'https://release.shepaw.com');
      expect(uri.path, '/api/v1/latest-macos.json');
      expect(uri.queryParameters['platform'], 'macos');
      expect(uri.queryParameters['currentVersion'], '1.0.22');
      expect(uri.queryParameters['buildNumber'], '1');
    });

    test('keeps a dynamic single endpoint without rewriting the path', () {
      final uri = UpdateService.resolveCheckUri(
        baseUrl: 'https://release.shepaw.com',
        endpoint: '/api/v1/check-update',
        platform: 'android',
        currentVersion: '1.0.22',
        buildNumber: '1',
      );

      expect(uri.path, '/api/v1/check-update');
      expect(uri.queryParameters['platform'], 'android');
    });
  });

  group('UpdateInfo static manifest', () {
    test('parses the sideload JSON fields the client actually reads', () {
      final info = UpdateInfo.fromJson({
        'version': '1.0.23',
        'buildNumber': '1',
        'description': 'notes',
        'isMandatory': false,
        'releaseDate': '2026-09-12T16:00:00Z',
        'downloadUrl':
            'https://release.shepaw.com/download/shepaw-1.0.23-android-release.apk',
        'fileSize': 10,
        'checksum':
            'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      });

      expect(info.version, '1.0.23');
      expect(info.downloadUrl.contains('android-release.apk'), isTrue);
      expect(info.checksum!.startsWith('sha256:'), isTrue);

      final current = VersionInfo.parse('1.0.22+1');
      final latest = VersionInfo.parse('${info.version}+1');
      expect(current.isLowerThan(latest), isTrue);
    });
  });

  group('UpdateChecksum', () {
    test('accepts sha256 prefix and rejects a mismatch', () {
      const hex =
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
      expect(
        UpdateChecksum.matchesBytes('hello'.codeUnits, 'sha256:$hex'),
        isTrue,
      );
      expect(
        UpdateChecksum.matchesBytes('hello'.codeUnits, 'sha256:${'0' * 64}'),
        isFalse,
      );
    });

    test('skips verification when checksum is omitted', () {
      expect(UpdateChecksum.matchesBytes([1, 2, 3], null), isTrue);
      expect(UpdateChecksum.matchesBytes([1, 2, 3], ''), isTrue);
    });

    test('rejects a malformed checksum', () {
      expect(UpdateChecksum.parseExpectedHex('md5:abc'), isNull);
      expect(UpdateChecksum.matchesBytes([1], 'not-a-hash'), isFalse);
    });
  });
}
