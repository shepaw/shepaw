import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/clis/shepaw/models/models_namespace.dart';
import 'package:shepaw/clis/shepaw/models/add_command.dart';
import 'package:shepaw/clis/shepaw/models/list_command.dart';
import 'package:shepaw/clis/shepaw/models/remove_command.dart';
import 'package:shepaw/clis/shepaw/models/show_command.dart';
import 'package:shepaw/clis/shepaw/models/update_command.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/model_registry.dart';
import 'package:shepaw/services/secure_key_manager.dart';

import '../storage/test_harness.dart';

/// Unit tests for the `models` CLI namespace.
///
/// 覆盖：namespace 注册与帮助、providers 知识输出、add/list/show/update/remove、
/// 去重守卫、API Key 的「只进不出」安全约定（明文绝不回显、写 SecureKeyManager）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    // 每个用例从空注册中心开始（单例，需清理上一个用例的残留）。
    for (final def in ModelRegistry.instance.definitions.toList()) {
      await ModelRegistry.instance.delete(def.id);
    }
  });

  group('models namespace registration', () {
    test('exposes all expected commands in help', () async {
      final help = await ModelsNamespace.instance.getHelpAsync();
      final commands = help['commands'] as Map<String, dynamic>;
      for (final name in [
        'list',
        'show',
        'providers',
        'add',
        'update',
        'remove',
        'agent-main',
      ]) {
        expect(commands.containsKey(name), true,
            reason: 'models namespace should expose $name');
      }
      expect(help['what_she_needs_to_know'], isA<List<dynamic>>());
      expect(help['rules'], isA<List<dynamic>>());
    });

    test('namespace help flag returns help instead of executing', () async {
      final result =
          await ModelsNamespace.instance.execute('', {'help': 'true'});
      expect(result['namespace'], 'models');
      expect(result['commands'], isA<Map>());
    });
  });

  group('models providers', () {
    test('lists built-in provider presets incl. DeepSeek facts', () async {
      final result = await ModelsNamespace.instance.execute('providers', {});
      expect(result['error'], isNull);
      final providers = result['providers'] as List<dynamic>;
      final deepseek = providers
          .whereType<Map<String, dynamic>>()
          .firstWhere((p) => p['name'] == 'DeepSeek');
      expect(deepseek['provider_type'], 'openai');
      expect(deepseek['default_api_base'], 'https://api.deepseek.com/v1');
      expect(deepseek['requires_api_key'], true);
      expect(result['facts'], isA<List<dynamic>>());
    });

    test('exposes the TokenHub preset', () async {
      final result = await ModelsNamespace.instance.execute('providers', {});
      final providers = result['providers'] as List<dynamic>;
      final tokenhub = providers
          .whereType<Map<String, dynamic>>()
          .firstWhere((p) => p['name'] == 'TokenHub');
      expect(tokenhub['provider_type'], 'openai');
      expect(tokenhub['default_api_base'], 'https://tokenhub.tencentmaas.com/v1');
      expect(tokenhub['default_model'], 'hy3');
      expect(tokenhub['requires_api_key'], true);
    });
  });

  group('models list', () {
    test('empty registry returns empty list', () async {
      final result = await ModelsListCommand().execute({});
      expect(result['models'], isEmpty);
      expect(result['count'], 0);
    });
  });

  group('models add', () {
    test('adds a DeepSeek model from provider preset', () async {
      final result = await ModelsAddCommand().execute({
        'provider': 'DeepSeek',
        'name': 'deepseek-chat',
        'display_name': 'DeepSeek Chat',
        'types': 'text',
      });
      expect(result['ok'], true);
      expect(result['error'], isNull);
      expect(result['action'], 'added');
      final model = result['model'] as Map<String, dynamic>;
      expect(model['model'], 'deepseek-chat');
      expect(model['api_base'], 'https://api.deepseek.com/v1');
      expect(model['has_api_key'], false);
      expect(result['needs_api_key'], true);

      final list = await ModelsListCommand().execute({});
      expect((list['models'] as List).length, 1);
    });

    test('adds a TokenHub model, api base filled from the preset', () async {
      // 不传 --api_base：必须落到 TokenHub 预设的 base（而非第一个 openai 预设）。
      final result = await ModelsAddCommand().execute({
        'provider': 'TokenHub',
        'name': 'hy3',
        'types': 'text',
      });
      expect(result['ok'], true);
      expect(result['error'], isNull);
      final model = result['model'] as Map<String, dynamic>;
      expect(model['provider'], 'openai');
      expect(model['model'], 'hy3');
      expect(model['api_base'], 'https://tokenhub.tencentmaas.com/v1');
      expect(result['requires_api_key'], true);
    });

    test('rejects duplicate (same model + api base)', () async {
      await ModelsAddCommand().execute({
        'provider': 'DeepSeek',
        'name': 'deepseek-chat',
      });
      final dup = await ModelsAddCommand().execute({
        'provider': 'DeepSeek',
        'name': 'deepseek-chat',
      });
      expect(dup['ok'], isNot(true));
      expect(dup['error'], contains('already configured'));
      expect(dup['suggestion'], contains('models update'));
    });

    test('api key is stored securely and never echoed', () async {
      final result = await ModelsAddCommand().execute({
        'provider': 'DeepSeek',
        'name': 'deepseek-r1',
        'api_key': 'sk-test-secret-123',
      });
      expect(result['ok'], true);
      final id = result['id'] as String;
      final json = result.toString();
      expect(json.contains('sk-test-secret-123'), isFalse,
          reason: 'API key must never be echoed in command output');

      // 密钥确实进入了安全存储。
      final stored = await SecureKeyManager.getSecureValue(
        SecureKeyManager.modelApiKeyStorageKey(id),
      );
      expect(stored, 'sk-test-secret-123');

      final model = result['model'] as Map<String, dynamic>;
      expect(model['has_api_key'], true);
      expect(result['needs_api_key'], false);
    });

    test('manual add without api base errors when no provider preset',
        () async {
      final result = await ModelsAddCommand().execute({'name': 'my-model'});
      expect(result['ok'], isNot(true));
      expect(result['error'], contains('--api_base'));
    });
  });

  group('models show / update / remove', () {
    late String id;

    setUp(() async {
      final result = await ModelsAddCommand().execute({
        'provider': 'DeepSeek',
        'name': 'deepseek-chat',
        'display_name': 'DeepSeek Chat',
        'api_key': 'sk-abc',
      });
      id = result['id'] as String;
    });

    test('show returns sanitized detail', () async {
      final result = await ModelsShowCommand().execute({'id': id});
      expect(result['model'], 'deepseek-chat');
      expect(result['has_api_key'], true);
      expect(result.toString().contains('sk-abc'), isFalse);
    });

    test('update display name / types / api base', () async {
      final result = await ModelsUpdateCommand().execute({
        'id': id,
        'display_name': 'DeepSeek Chat V3',
        'types': 'text,imageUnderstanding',
        'api_base': 'https://api.deepseek.com/v1',
      });
      expect(result['ok'], true);
      expect((result['changes'] as List).contains('display_name'), true);
      final model = result['model'] as Map<String, dynamic>;
      expect(model['display_name'], 'DeepSeek Chat V3');
      expect(model['model_types'], contains('imageUnderstanding'));
    });

    test('update replaces api key; clear_api_key removes it', () async {
      final replaced = await ModelsUpdateCommand().execute({
        'id': id,
        'api_key': 'sk-new-key',
      });
      expect(replaced['ok'], true);
      final storedNew = await SecureKeyManager.getSecureValue(
        SecureKeyManager.modelApiKeyStorageKey(id),
      );
      expect(storedNew, 'sk-new-key');

      final cleared =
          await ModelsUpdateCommand().execute({'id': id, 'clear_api_key': ''});
      expect(cleared['ok'], true);
      final storedAfter = await SecureKeyManager.getSecureValue(
        SecureKeyManager.modelApiKeyStorageKey(id),
      );
      expect(storedAfter, isNull);
      final model = cleared['model'] as Map<String, dynamic>;
      expect(model['has_api_key'], false);
    });

    test('remove by id deletes the definition', () async {
      final result = await ModelsRemoveCommand().execute({'id': id});
      expect(result['ok'], true);
      expect(result['action'], 'removed');
      final list = await ModelsListCommand().execute({});
      expect(list['models'], isEmpty);
    });

    test('remove resolves by route model name', () async {
      final result =
          await ModelsRemoveCommand().execute({'model': 'deepseek-chat'});
      expect(result['ok'], true);
      expect(result['id'], id);
    });

    test('update unknown id errors', () async {
      final result = await ModelsUpdateCommand()
          .execute({'id': 'no-such-id', 'display_name': 'x'});
      expect(result['ok'], isNot(true));
      expect(result['error'], contains('not found'));
    });
  });

  // 引用保护：usageByModelId 上移到 ModelUsageService 后，CLI 侧行为必须
  // 逐字不变（list 的 used_by 结构、remove 的拒绝与 --yes 放行）。
  group('models usage guard', () {
    late String id;

    setUp(() async {
      final result = await ModelsAddCommand().execute({
        'provider': 'DeepSeek',
        'name': 'deepseek-chat',
        'display_name': 'DeepSeek Chat',
      });
      id = result['id'] as String;
    });

    tearDown(() async {
      // 用例间清掉 agent 行，避免互相干扰（agents 表不在 registry 清理范围内）。
      for (final agent in await LocalDatabaseService().getAllRemoteAgents()) {
        await LocalDatabaseService().deleteRemoteAgent(agent.id);
      }
    });

    Future<void> createReferencingAgent(String name) async {
      await LocalDatabaseService().createRemoteAgent(
        RemoteAgent(
          id: 'agent-$name',
          name: name,
          token: '',
          endpoint: '',
          protocol: ProtocolType.acp,
          connectionType: ConnectionType.http,
          createdAt: 0,
          updatedAt: 0,
          metadata: {'main_model_id': id, 'llm_provider': 'openai'},
        ),
      );
    }

    test('list marks the definition as used_by the referencing agent', () async {
      await createReferencingAgent('Alice');

      final list = await ModelsListCommand().execute({});
      final entry = (list['models'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((m) => m['id'] == id);
      expect(entry['used_by']['main'], [
        {'id': 'agent-Alice', 'name': 'Alice'},
      ]);
      expect(entry['used_by']['scenario'], isEmpty);
    });

    test('remove refuses while referenced, listing the agents', () async {
      await createReferencingAgent('Alice');

      final refused = await ModelsRemoveCommand().execute({'id': id});
      expect(refused['error'], contains('still referenced'));
      expect(refused['used_by']['main'], [
        {'id': 'agent-Alice', 'name': 'Alice'},
      ]);
      // 拒绝时定义必须还在。
      expect(ModelRegistry.instance.getById(id), isNotNull);
    });

    test('remove with --yes deletes anyway and echoes used_by', () async {
      await createReferencingAgent('Alice');

      final forced =
          await ModelsRemoveCommand().execute({'id': id, 'yes': 'true'});
      expect(forced['ok'], true);
      expect(forced['action'], 'removed');
      expect(forced['used_by']['main'], [
        {'id': 'agent-Alice', 'name': 'Alice'},
      ]);
      expect(ModelRegistry.instance.getById(id), isNull);
    });
  });
}
