import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/utils/engine_avatars.dart';

void main() {
  group('defaultAvatarForEngine', () {
    test('known engines use the bundled svg, unknown ones stay generic', () {
      expect(
        defaultAvatarForEngine('cursor'),
        'assets/images/engines/cursor.svg',
      );
      expect(defaultAvatarForEngine('not-an-engine'), kGenericDefaultAvatar);
      expect(defaultAvatarForEngine(null), kGenericDefaultAvatar);
      expect(defaultAvatarForEngine(''), kGenericDefaultAvatar);
    });
  });

  group('isGenericDefaultAvatar', () {
    test('treats placeholders and legacy engine markers as generic', () {
      expect(isGenericDefaultAvatar(null), isTrue);
      expect(isGenericDefaultAvatar(''), isTrue);
      expect(isGenericDefaultAvatar(kGenericDefaultAvatar), isTrue);
      expect(isGenericDefaultAvatar('engine-avatar:cursor'), isTrue);
      expect(
        isGenericDefaultAvatar('assets/images/engines/cursor.svg'),
        isTrue,
      );
      expect(isGenericDefaultAvatar('/tmp/avatars/x.png'), isFalse);
      expect(isGenericDefaultAvatar('🧠'), isFalse);
    });
  });
}
