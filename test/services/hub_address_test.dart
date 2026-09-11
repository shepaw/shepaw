import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/hub_address.dart';

void main() {
  group('normalizeHubDashboardUrl', () {
    String? norm(String raw) => normalizeHubDashboardUrl(raw)?.toString();

    test('bare host gets http and the default port', () {
      expect(norm('192.168.1.5'), 'http://192.168.1.5:4000');
    });

    test('bare host:port is not mistaken for a scheme', () {
      // 回归：`Uri.parse('192.168.1.5:4000')` 会抛 FormatException
      // （把 `192.168.1.5` 当 scheme），而 `Uri.parse('hub:4000')` 会真的把
      // `hub` 当 scheme。两种都不能走 `uri.hasScheme` 分支。
      expect(norm('192.168.1.5:4000'), 'http://192.168.1.5:4000');
      expect(norm('hub.local:4000'), 'http://hub.local:4000');
    });

    test('trailing slash, path, query and fragment are dropped', () {
      expect(norm('http://192.168.1.5:4000/'), 'http://192.168.1.5:4000');
      expect(
        norm('http://192.168.1.5:4000/instances?tab=1#top'),
        'http://192.168.1.5:4000',
      );
      expect(norm('192.168.1.5:4000/api/health'), 'http://192.168.1.5:4000');
    });

    test('surrounding whitespace is trimmed', () {
      expect(norm('  192.168.1.5:4000  '), 'http://192.168.1.5:4000');
    });

    test('explicit https keeps its scheme and does not get :4000', () {
      expect(norm('https://hub.example.com/'), 'https://hub.example.com');
    });

    test('explicit https with a port keeps the port', () {
      expect(
        norm('https://hub.example.com:8443'),
        'https://hub.example.com:8443',
      );
    });

    test('explicit http port is preserved', () {
      expect(norm('http://10.0.0.7:8080'), 'http://10.0.0.7:8080');
    });

    test('IPv6 literal', () {
      expect(norm('[fe80::1]:4000'), 'http://[fe80::1]:4000');
      expect(norm('http://[fd00::1]:4000'), 'http://[fd00::1]:4000');
    });

    test('custom default port', () {
      expect(
        norm('192.168.1.5'),
        'http://192.168.1.5:4000',
      );
      expect(
        normalizeHubDashboardUrl('192.168.1.5', defaultPort: 8080)?.toString(),
        'http://192.168.1.5:8080',
      );
    });

    test('rejects empty and blank input', () {
      expect(normalizeHubDashboardUrl(''), isNull);
      expect(normalizeHubDashboardUrl('   '), isNull);
    });

    test('rejects non-http(s) schemes', () {
      expect(normalizeHubDashboardUrl('ftp://h'), isNull);
      expect(normalizeHubDashboardUrl('ws://192.168.1.5:4000'), isNull);
      expect(
        normalizeHubDashboardUrl('shepaw://peer?local=ws://x&code=ABC'),
        isNull,
      );
    });

    test('rejects userInfo', () {
      expect(normalizeHubDashboardUrl('http://user:pass@h'), isNull);
      expect(normalizeHubDashboardUrl('http://user@192.168.1.5:4000'), isNull);
    });

    test('rejects an empty host', () {
      expect(normalizeHubDashboardUrl('http://:4000'), isNull);
      expect(normalizeHubDashboardUrl('http://'), isNull);
    });

    test('rejects out-of-range ports', () {
      // Uri.parse 不会为 99999 抛错，必须自己判。
      expect(normalizeHubDashboardUrl('http://192.168.1.5:99999'), isNull);
      expect(normalizeHubDashboardUrl('http://192.168.1.5:0'), isNull);
    });

    test('is idempotent', () {
      for (final raw in const [
        '192.168.1.5',
        '192.168.1.5:4000',
        'http://192.168.1.5:4000/',
        'https://hub.example.com/',
        'https://hub.example.com:8443',
        '[fe80::1]:4000',
      ]) {
        final once = normalizeHubDashboardUrl(raw)!;
        final twice = normalizeHubDashboardUrl(once.toString())!;
        expect(twice, once, reason: 'not idempotent for $raw');
      }
    });
  });

  group('isPrivateOrLoopback', () {
    test('private and loopback ranges are true', () {
      for (final host in const [
        '127.0.0.1',
        '127.1.2.3',
        '10.0.0.1',
        '192.168.1.5',
        '172.16.0.1',
        '172.31.255.254',
        '169.254.1.1',
        'localhost',
        'LOCALHOST',
        '::1',
        '[::1]',
        'fe80::1',
        'fd00::1',
      ]) {
        expect(isPrivateOrLoopback(host), isTrue, reason: host);
      }
    });

    test('public addresses and hostnames are false', () {
      for (final host in const [
        '8.8.8.8',
        'hub.example.com',
        '172.32.0.1',
        '172.15.0.1',
        '11.0.0.1',
        '192.169.1.1',
        '2001:db8::1',
        '',
      ]) {
        expect(isPrivateOrLoopback(host), isFalse, reason: host);
      }
    });

    test('malformed IPv4 is not treated as private', () {
      expect(isPrivateOrLoopback('192.168.1'), isFalse);
      expect(isPrivateOrLoopback('192.168.1.999'), isFalse);
      expect(isPrivateOrLoopback('192.168.1.a'), isFalse);
    });
  });

  group('isInsecureDashboard', () {
    test('public http needs a warning', () {
      expect(isInsecureDashboard(Uri.parse('http://8.8.8.8:4000')), isTrue);
      expect(
        isInsecureDashboard(Uri.parse('http://hub.example.com:4000')),
        isTrue,
      );
    });

    test('private http and public https do not', () {
      expect(isInsecureDashboard(Uri.parse('http://192.168.1.5:4000')), isFalse);
      expect(isInsecureDashboard(Uri.parse('http://127.0.0.1:4000')), isFalse);
      expect(isInsecureDashboard(Uri.parse('https://hub.example.com')), isFalse);
    });
  });
}
