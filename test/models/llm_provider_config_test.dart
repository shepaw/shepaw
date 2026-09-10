import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/llm_provider_config.dart';

/// `llmProviders` 预设表的不变量。
///
/// 这张表被三处"顺序 + 首次命中"逻辑索引（UI 预选第二轮匹配、CLI
/// `resolveProvider`、`providerForApiBase`），任何一条不变量被破坏都会
/// 静默改变存量模型定义的行为，因此在这里加便宜守卫。
void main() {
  group('llmProviders invariants', () {
    test('preset names are unique (case-insensitive)', () {
      // resolveProvider 会把输入 lowercase 后比对 name，重名会产生歧义。
      final seen = <String, String>{};
      for (final p in llmProviders) {
        final key = p.name.toLowerCase();
        expect(seen.containsKey(key), false,
            reason: 'duplicate provider name: ${p.name} '
                '(also used by ${seen[key]})');
        seen[key] = p.name;
      }
    });

    test('api bases are unique after stripping the trailing slash', () {
      // providerForApiBase 与 UI 预选第一轮都按精确 apiBase 匹配。
      final seen = <String, String>{};
      for (final p in llmProviders) {
        final base = p.defaultApiBase.endsWith('/')
            ? p.defaultApiBase.substring(0, p.defaultApiBase.length - 1)
            : p.defaultApiBase;
        expect(seen.containsKey(base), false,
            reason: 'duplicate api base: $base '
                '(used by ${seen[base]} and ${p.name})');
        seen[base] = p.name;
      }
    });

    test('provider types stay within the supported protocols', () {
      const supported = {'openai', 'claude', 'glm'};
      for (final p in llmProviders) {
        expect(supported.contains(p.providerType), true,
            reason: '${p.name} has unsupported providerType '
                '"${p.providerType}"');
      }
    });

    test('modelsPath, when set, is an absolute path', () {
      // 通用拉取分支拼 `{apiBase}{modelsPath}`；相对路径会拼出非法 URL。
      for (final p in llmProviders) {
        final path = p.modelsPath;
        if (path == null) continue;
        expect(path.startsWith('/'), true,
            reason: '${p.name} modelsPath must start with "/", got "$path"');
      }
    });

    test('the first openai preset is still OpenAI', () {
      // index 0 是 providerType 匹配链路的默认落点，追加新预设不得改变它。
      expect(llmProviders.first.name, 'OpenAI');
      expect(llmProviders.first.providerType, 'openai');
    });
  });
}
