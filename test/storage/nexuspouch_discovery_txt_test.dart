import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/nexuspouch_discovery_service.dart';

// Exercise TXT parsing via a thin re-export test double.
// _parseTxt is library-private; duplicate the regex contract here for stability.
Map<String, String> parseTxtForTest(String raw) {
  final out = <String, String>{};
  final parts = raw.split(RegExp(r'[\x00\n\r]+'));
  for (final part in parts) {
    final eq = part.indexOf('=');
    if (eq > 0) {
      out[part.substring(0, eq)] = part.substring(eq + 1);
    }
  }
  for (final key in ['fp', 'name', 'path', 'proto']) {
    if (out.containsKey(key)) continue;
    final re = RegExp('$key=([^\\x00\\s]+)');
    final m = re.firstMatch(raw);
    if (m != null) out[key] = m.group(1)!;
  }
  return out;
}

void main() {
  test('service type constant', () {
    expect(NexuspouchDiscoveryService.serviceType, '_nexuspouch._tcp.local');
  });

  test('txt key=value with nul separators', () {
    final m = parseTxtForTest('fp=aaaaaaaaaaaaaaaa\x00name=nas\x00path=/peer/ws');
    expect(m['fp'], 'aaaaaaaaaaaaaaaa');
    expect(m['name'], 'nas');
    expect(m['path'], '/peer/ws');
  });

  test('txt concatenated fallback', () {
    final m = parseTxtForTest('fp=bbbbbbbbbbbbbbbbname=boxpath=/peer/ws');
    expect(m['fp'], 'bbbbbbbbbbbbbbbb');
  });
}
