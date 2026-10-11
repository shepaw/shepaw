import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  group('SheService.resolveDisplayName', () {
    test('maps functional default She to localized default', () {
      expect(SheService.resolveDisplayName('She', '惜宝'), '惜宝');
      expect(SheService.resolveDisplayName('She', 'She'), 'She');
    });

    test('maps empty to localized default', () {
      expect(SheService.resolveDisplayName('', '惜宝'), '惜宝');
      expect(SheService.resolveDisplayName(null, '惜宝'), '惜宝');
    });

    test('keeps a custom renamed value', () {
      expect(SheService.resolveDisplayName('小橘', '惜宝'), '小橘');
      expect(SheService.resolveDisplayName('惜宝酱', '惜宝'), '惜宝酱');
    });
  });

  group('SheService.displayAvatar', () {
    test('惜宝一律用灵宠图，忽略库里的旧爪印', () {
      expect(
        SheService.displayAvatar(
          id: SheService.sheId,
          stored: '/tmp/old-paw.png',
        ),
        SheService.sheAvatar,
      );
      expect(
        SheService.displayAvatar(
          id: 'peer-local',
          stored: '/tmp/old-paw.png',
          metadata: const {'is_she': true},
        ),
        SheService.sheAvatar,
      );
    });

    test('其他助手保持自己的头像', () {
      expect(
        SheService.displayAvatar(
          id: 'agent-1',
          stored: 'assets/images/engines/cursor.svg',
        ),
        'assets/images/engines/cursor.svg',
      );
    });
  });

  group('SheService.normalizeStoredName', () {
    test('collapses localized default and She back to functional She', () {
      expect(SheService.normalizeStoredName('She', '惜宝'), 'She');
      expect(SheService.normalizeStoredName('惜宝', '惜宝'), 'She');
      expect(SheService.normalizeStoredName('', '惜宝'), 'She');
      expect(SheService.normalizeStoredName('  惜宝  ', '惜宝'), 'She');
    });

    test('keeps a custom rename', () {
      expect(SheService.normalizeStoredName('小橘', '惜宝'), '小橘');
    });
  });
}
