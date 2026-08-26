import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shepaw/models/model_definition.dart';
import 'package:shepaw/services/model_catalog_service.dart';
import 'package:shepaw/utils/exceptions.dart';

ModelCatalogService _service({
  required MockClient client,
  String base = 'https://catalog.test',
}) {
  return ModelCatalogService(
    httpClient: client,
    baseUrlProvider: () async => base,
  );
}

void main() {
  group('ModelCatalogService', () {
    test('解析模型目录（字段 + modelTypes）', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://catalog.test/api/v1/models');
        return http.Response(
          jsonEncode({
            'models': [
              {
                'id': 'lm_1',
                'provider': 'openai',
                'providerLabel': 'DeepSeek',
                'name': 'deepseek-chat',
                'displayName': 'DeepSeek Chat',
                'description': '通用对话',
                'apiBase': 'https://api.deepseek.com/v1',
                'requiresApiKey': true,
                'modelTypes': ['text', 'imageUnderstanding'],
                'stream': true,
              },
              {
                'id': 'lm_2',
                'provider': 'openai',
                'providerLabel': 'Ollama',
                'name': 'llama3',
                'displayName': 'Llama 3',
                'apiBase': 'http://localhost:11434/v1',
                'requiresApiKey': false,
                'modelTypes': ['text'],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = _service(client: client);
      final models = await service.fetchModels(forceRefresh: true);

      expect(models, hasLength(2));

      final deepseek = models[0];
      expect(deepseek.provider, 'openai');
      expect(deepseek.providerLabel, 'DeepSeek');
      expect(deepseek.name, 'deepseek-chat');
      expect(deepseek.displayName, 'DeepSeek Chat');
      expect(deepseek.apiBase, 'https://api.deepseek.com/v1');
      expect(deepseek.requiresApiKey, isTrue);
      expect(deepseek.stream, isTrue);
      expect(deepseek.modelTypes, containsAll([
        ModelType.text,
        ModelType.imageUnderstanding,
      ]));

      final ollama = models[1];
      expect(ollama.requiresApiKey, isFalse);
      expect(ollama.apiPath, isNull);
      service.close();
    });

    test('非 200 抛 ApiException', () async {
      final client = MockClient((_) async => http.Response('oops', 500));
      final service = _service(client: client);
      expect(
        service.fetchModels(forceRefresh: true),
        throwsA(isA<ApiException>()),
      );
      service.close();
    });

    test('网络异常抛 NetworkException', () async {
      final client = MockClient((_) async {
        throw http.ClientException('connection refused');
      });
      final service = _service(client: client);
      expect(
        service.fetchModels(forceRefresh: true),
        throwsA(isA<NetworkException>()),
      );
      service.close();
    });

    test('1 小时内命中缓存，不重复请求', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode({'models': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = _service(client: client);

      await service.fetchModels(forceRefresh: true);
      await service.fetchModels();
      await service.fetchModels();

      expect(calls, 1, reason: '缓存命中时不应再次请求');

      await service.fetchModels(forceRefresh: true);
      expect(calls, 2, reason: 'forceRefresh 应绕过缓存');
      service.close();
    });
  });
}
