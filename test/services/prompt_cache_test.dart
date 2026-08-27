import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/prompt_cache.dart';

void main() {
  group('PromptCache', () {
    test('claudeSystem caches the static prefix and leaves the tail uncached', () {
      final system = PromptCache.claudeSystem(
        staticPrefix: 'STATIC',
        dynamicSuffix: 'NOW',
      ) as List;

      expect(system, hasLength(2));
      expect(system[0]['text'], 'STATIC');
      expect(system[0]['cache_control'], PromptCache.ephemeral);
      expect(system[1]['text'], 'NOW');
      expect(system[1].containsKey('cache_control'), isFalse);
    });

    test('claudeSystemBlob wraps a single string with a cache breakpoint', () {
      final system = PromptCache.claudeSystemBlob('GROUP') as List;
      expect(system, hasLength(1));
      expect(system[0]['cache_control'], PromptCache.ephemeral);
      expect(system[0]['text'], 'GROUP');
    });

    test('markLastTool attaches cache_control only to the last tool', () {
      final marked = PromptCache.markLastTool([
        {'name': 'a'},
        {'name': 'b'},
      ]);
      expect(marked[0].containsKey('cache_control'), isFalse);
      expect(marked[1]['cache_control'], PromptCache.ephemeral);
      expect(marked[1]['name'], 'b');
    });
  });

  group('BuiltSystemPrompt', () {
    test('full concatenates prefix then suffix', () {
      const built = BuiltSystemPrompt(
        staticPrefix: 'STATIC',
        dynamicSuffix: 'TIME',
      );
      expect(built.full, 'STATIC\n\nTIME');
    });

    test('toClaudeSystem matches PromptCache.claudeSystem', () {
      const built = BuiltSystemPrompt(
        staticPrefix: 'STATIC',
        dynamicSuffix: 'TIME',
      );
      final system = built.toClaudeSystem() as List;
      expect(system[0]['cache_control'], PromptCache.ephemeral);
      expect(system[1]['text'], 'TIME');
    });
  });
}
