import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shepaw/services/openai_compatible_models_service.dart';
import 'package:shepaw/utils/exceptions.dart';

/// `OpenAiCompatibleModelsService` 单元测试。
///
/// 全程使用 MockClient —— **绝不打真实端点**。
void main() {
  const base = 'https://tokenhub.tencentmaas.com/v1';

  setUp(() {
    // 缓存是静态的，单 isolate 跑整个文件会串用例。
    OpenAiCompatibleModelsService.clearCache();
  });

  /// 构造一个只关心「返回什么」的 mock，并暴露最后一次请求。
  ({OpenAiCompatibleModelsService service, List<http.Request> seen})
      serviceWith(http.Response Function(http.Request req) handler) {
    final seen = <http.Request>[];
    final client = MockClient((req) async {
      seen.add(req);
      return handler(req);
    });
    return (
      service: OpenAiCompatibleModelsService(httpClient: client),
      seen: seen,
    );
  }

  http.Response json200(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );

  group('happy path', () {
    test('parses data[] and sends a Bearer token', () async {
      final (:service, :seen) = serviceWith((_) => json200({
            'object': 'list',
            'data': [
              {
                'id': 'hy3',
                'object': 'model',
                'name': 'Hunyuan 3',
                'created': 1700000000,
                'status': 'ready',
              },
              {'id': 'glm-5.3', 'object': 'model'},
            ],
          }));

      final models = await service.getModels(
        apiBase: base,
        modelsPath: '/models',
        apiKey: 'sk-test-key',
        providerLabel: 'TokenHub',
      );

      expect(models.map((m) => m.id).toList(), ['glm-5.3', 'hy3']);
      final hy3 = models.firstWhere((m) => m.id == 'hy3');
      expect(hy3.name, 'Hunyuan 3');
      expect(hy3.created, 1700000000);
      expect(hy3.status, 'ready');

      expect(seen, hasLength(1));
      expect(seen.single.url.toString(), '$base/models');
      expect(seen.single.headers['Authorization'], 'Bearer sk-test-key');
    });

    test('strips a trailing slash from apiBase', () async {
      final (:service, :seen) = serviceWith((_) => json200({'data': []}));
      await service.getModels(apiBase: '$base/', modelsPath: '/models');
      expect(seen.single.url.toString(), '$base/models');
    });
  });

  group('response tolerance', () {
    test('accepts a bare top-level array', () async {
      final (:service, :seen) = serviceWith((_) => json200([
            {'id': 'kimi-k3'},
            {'id': 'minimax-m3'},
          ]));

      final models =
          await service.getModels(apiBase: base, modelsPath: '/models');
      expect(models.map((m) => m.id).toList(), ['kimi-k3', 'minimax-m3']);
      expect(seen, hasLength(1));
    });

    test('drops entries with a missing or empty id', () async {
      final (:service, :seen) = serviceWith((_) => json200({
            'data': [
              {'id': 'hy3'},
              {'name': 'no id here'},
              {'id': ''},
              'not-a-map',
              {'id': 'qwen3.5-flash'},
            ],
          }));

      final models =
          await service.getModels(apiBase: base, modelsPath: '/models');
      expect(models.map((m) => m.id).toList(), ['hy3', 'qwen3.5-flash']);
    });
  });

  group('error mapping', () {
    test('401 and 403 map to AuthException', () async {
      for (final status in [401, 403]) {
        OpenAiCompatibleModelsService.clearCache();
        final (:service, :seen) =
            serviceWith((_) => http.Response('unauthorized', status));
        await expectLater(
          service.getModels(
            apiBase: base,
            modelsPath: '/models',
            providerLabel: 'TokenHub',
          ),
          throwsA(isA<AuthException>()),
          reason: 'status $status should map to AuthException',
        );
      }
    });

    test('404 explains the missing models endpoint', () async {
      final (:service, :seen) =
          serviceWith((_) => http.Response('not found', 404));
      await expectLater(
        service.getModels(
          apiBase: base,
          modelsPath: '/models',
          providerLabel: 'TokenHub',
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('未提供模型列表接口'),
          ),
        ),
      );
    });

    test('other non-200 maps to ApiException with the status code', () async {
      final (:service, :seen) =
          serviceWith((_) => http.Response('boom', 500));
      await expectLater(
        service.getModels(
          apiBase: base,
          modelsPath: '/models',
          providerLabel: 'TokenHub',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 500)
              .having((e) => e.message, 'message', contains('500')),
        ),
      );
    });

    test('an error field in the body maps to ApiException', () async {
      final (:service, :seen) = serviceWith(
        (_) => json200({'error': {'message': 'quota exceeded'}}),
      );
      await expectLater(
        service.getModels(
          apiBase: base,
          modelsPath: '/models',
          providerLabel: 'TokenHub',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', contains('quota exceeded')),
        ),
      );
    });

    test('a ClientException maps to NetworkException', () async {
      final (:service, :seen) = serviceWith(
        (_) => throw http.ClientException('connection refused'),
      );
      await expectLater(
        service.getModels(apiBase: base, modelsPath: '/models'),
        throwsA(isA<NetworkException>()),
      );
    });

    test('invalid JSON maps to ApiException, not a raw FormatException',
        () async {
      final (:service, :seen) = serviceWith((_) => http.Response(
            '<html>gateway timeout</html>',
            200,
            headers: {'content-type': 'text/html'},
          ));
      await expectLater(
        service.getModels(
          apiBase: base,
          modelsPath: '/models',
          providerLabel: 'TokenHub',
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('响应格式错误'),
          ),
        ),
      );
    });

    test('an unexpected root type maps to ApiException', () async {
      final (:service, :seen) = serviceWith((_) => json200('just a string'));
      await expectLater(
        service.getModels(
          apiBase: base,
          modelsPath: '/models',
          providerLabel: 'TokenHub',
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('api key sanitizing', () {
    test('strips newlines/tabs before sending the key', () async {
      // 粘贴带换行的 Key 是常见情况：清洗后照常发请求。
      final (:service, :seen) = serviceWith((_) => json200({'data': []}));
      await service.getModels(
        apiBase: base,
        modelsPath: '/models',
        apiKey: '  sk-abc\n',
        providerLabel: 'TokenHub',
      );
      expect(seen.single.headers['Authorization'], 'Bearer sk-abc');
    });

    test('rejects a key with a space before any request', () async {
      // 空格 (\x20) 不在 \x21-\x7E 内，且不会被清洗掉 → 非法 header 字符。
      final (:service, :seen) = serviceWith((_) => json200({'data': []}));
      await expectLater(
        service.getModels(
          apiBase: base,
          modelsPath: '/models',
          apiKey: 'sk-bad key',
          providerLabel: 'TokenHub',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(seen, isEmpty, reason: 'must not hit the network');
    });

    test('rejects a key with non-ASCII characters', () async {
      final (:service, :seen) = serviceWith((_) => json200({'data': []}));
      await expectLater(
        service.getModels(
          apiBase: base,
          modelsPath: '/models',
          apiKey: 'sk-密钥',
          providerLabel: 'TokenHub',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(seen, isEmpty);
    });
  });

  group('cache', () {
    test('two calls without forceRefresh hit the network once', () async {
      final (:service, :seen) = serviceWith((_) => json200({
            'data': [
              {'id': 'hy3'},
            ],
          }));

      final first =
          await service.getModels(apiBase: base, modelsPath: '/models');
      final second =
          await service.getModels(apiBase: base, modelsPath: '/models');

      expect(first.map((m) => m.id), ['hy3']);
      expect(second.map((m) => m.id), ['hy3']);
      expect(seen, hasLength(1), reason: 'second call should be a cache hit');
    });

    test('forceRefresh bypasses the cache', () async {
      final (:service, :seen) = serviceWith((_) => json200({
            'data': [
              {'id': 'hy3'},
            ],
          }));

      await service.getModels(apiBase: base, modelsPath: '/models');
      await service
          .getModels(apiBase: base, modelsPath: '/models', forceRefresh: true);

      expect(seen, hasLength(2));
    });

    test('a different apiBase is a different cache entry', () async {
      final (:service, :seen) = serviceWith((_) => json200({
            'data': [
              {'id': 'hy3'},
            ],
          }));

      await service.getModels(apiBase: base, modelsPath: '/models');
      await service.getModels(
        apiBase: 'https://tokenhub-intl.tencentmaas.com/v1',
        modelsPath: '/models',
      );

      expect(seen, hasLength(2),
          reason: 'cache must be keyed by (apiBase, modelsPath)');
    });

    test('clearCache forces the next call to hit the network', () async {
      final (:service, :seen) = serviceWith((_) => json200({
            'data': [
              {'id': 'hy3'},
            ],
          }));

      await service.getModels(apiBase: base, modelsPath: '/models');
      OpenAiCompatibleModelsService.clearCache();
      await service.getModels(apiBase: base, modelsPath: '/models');

      expect(seen, hasLength(2));
    });
  });
}
