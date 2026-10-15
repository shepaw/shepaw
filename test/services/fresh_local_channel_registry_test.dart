import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/session/fresh_local_channel_registry.dart';

void main() {
  final t0 = DateTime(2026, 10, 15, 12);

  group('FreshLocalChannelRegistry', () {
    test('标记过的会话才算「本机刚建」', () {
      final registry = FreshLocalChannelRegistry();
      expect(registry.isFresh('dm_1', now: t0), isFalse);

      registry.mark('dm_1', now: t0);
      expect(registry.isFresh('dm_1', now: t0), isTrue);
      // 别的 id 不受影响。
      expect(registry.isFresh('dm_2', now: t0), isFalse);
    });

    test('会话有内容后 clear 掉，回到「要去主机读」', () {
      final registry = FreshLocalChannelRegistry();
      registry.mark('dm_1', now: t0);
      registry.clear('dm_1');
      expect(registry.isFresh('dm_1', now: t0), isFalse);
    });

    test('clear 没标记过的 id 是空操作', () {
      final registry = FreshLocalChannelRegistry();
      expect(() => registry.clear('nobody'), returnsNormally);
      registry.mark('dm_1', now: t0);
      registry.clear('nobody');
      expect(registry.isFresh('dm_1', now: t0), isTrue);
    });

    test('标记会过期：连点新建后没人来 clear 的那条不会永久压掉主机回读', () {
      final registry =
          FreshLocalChannelRegistry(ttl: const Duration(minutes: 10));
      registry.mark('dm_1', now: t0);

      expect(registry.isFresh('dm_1', now: t0.add(const Duration(minutes: 9))),
          isTrue);
      expect(
        registry.isFresh('dm_1', now: t0.add(const Duration(minutes: 10))),
        isFalse,
      );
      // 过期即清掉，不会留着一个永远新鲜的幽灵标记。
      expect(registry.isFresh('dm_1', now: t0), isFalse);
    });

    test('超出容量先丢最旧的', () {
      final registry = FreshLocalChannelRegistry(maxEntries: 2);
      registry.mark('oldest', now: t0);
      registry.mark('mid', now: t0);
      registry.mark('newest', now: t0);

      expect(registry.isFresh('oldest', now: t0), isFalse);
      expect(registry.isFresh('mid', now: t0), isTrue);
      expect(registry.isFresh('newest', now: t0), isTrue);
    });

    test('重复 mark 同一个 id 只占一格', () {
      final registry = FreshLocalChannelRegistry(maxEntries: 2);
      registry.mark('a', now: t0);
      registry.mark('a', now: t0);
      registry.mark('b', now: t0);

      // a 只占一格，b 进来没挤掉任何人。若 a 占了两次，这里 a 就被淘汰了。
      expect(registry.isFresh('a', now: t0), isTrue);
      expect(registry.isFresh('b', now: t0), isTrue);
    });

    test('容量内不会误伤', () {
      final registry = FreshLocalChannelRegistry(maxEntries: 64);
      for (var i = 0; i < 64; i++) {
        registry.mark('dm_$i', now: t0);
      }
      for (var i = 0; i < 64; i++) {
        expect(registry.isFresh('dm_$i', now: t0), isTrue);
      }
    });
  });
}
