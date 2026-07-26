import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/volume_usage.dart';

void main() {
  group('VolumeUsage.parseDfKP', () {
    test('解析 POSIX df -kP', () {
      const out = '''
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s5 1000000 800000 200000 80% /System/Volumes/Data
''';
      final v = VolumeUsage.parseDfKP(out)!;
      expect(v.totalBytes, 1000000 * 1024);
      expect(v.freeBytes, 200000 * 1024);
      expect(v.usedRatio, closeTo(0.8, 1e-9));
      expect(v.needsAttention, isTrue);
    });

    test('低于 80% 不告警', () {
      const out = '''
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/root 1000 500 500 50% /
''';
      final v = VolumeUsage.parseDfKP(out)!;
      expect(v.usedRatio, closeTo(0.5, 1e-9));
      expect(v.needsAttention, isFalse);
    });

    test('空/坏输出返回 null', () {
      expect(VolumeUsage.parseDfKP(''), isNull);
      expect(VolumeUsage.parseDfKP('Filesystem only'), isNull);
    });
  });

  group('VolumeUsage.parseWmicValue', () {
    test('解析 wmic value 格式', () {
      const out = '''
FreeSpace=2000000000
Size=10000000000

''';
      final v = VolumeUsage.parseWmicValue(out)!;
      expect(v.freeBytes, 2000000000);
      expect(v.totalBytes, 10000000000);
      expect(v.needsAttention, isTrue); // 80% used
    });
  });
}
