import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/model_routing_config.dart';

void main() {
  group('ModalityType Tests', () {
    test('should have correct labels', () {
      expect(ModalityType.text.label, 'Text');
      expect(ModalityType.image.label, 'Image');
      expect(ModalityType.audio.label, 'Audio');
      expect(ModalityType.video.label, 'Video');
    });

    test('should have correct icons', () {
      expect(ModalityType.text.icon, '\u{1F4DD}');
      expect(ModalityType.image.icon, '\u{1F5BC}');
      expect(ModalityType.audio.icon, '\u{1F3B5}');
      expect(ModalityType.video.icon, '\u{1F3AC}');
    });

    test('should have 4 values', () {
      expect(ModalityType.values.length, 7);
    });
  });

  group('ModelRouteConfig Tests', () {
    test('should create empty config', () {
      const config = ModelRouteConfig();

      expect(config.provider, isNull);
      expect(config.model, isNull);
      expect(config.apiBase, isNull);
      expect(config.apiKey, isNull);
      expect(config.stream, isNull);
      expect(config.apiPath, isNull);
      expect(config.requestBodyTemplate, isNull);
      expect(config.responseBodyPath, isNull);
      expect(config.isEmpty, true);
    });

    test('should create config with all fields', () {
      const config = ModelRouteConfig(
        provider: 'openai',
        model: 'gpt-4o',
        apiBase: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
      );

      expect(config.provider, 'openai');
      expect(config.model, 'gpt-4o');
      expect(config.apiBase, 'https://api.openai.com/v1');
      expect(config.apiKey, 'sk-test');
      expect(config.isEmpty, false);
    });

    test('should create config with new non-SSE fields', () {
      const config = ModelRouteConfig(
        model: 'cogview-3-plus',
        stream: false,
        apiPath: '/images/generations',
        requestBodyTemplate: '{"model":"\$model","prompt":"\$prompt"}',
        responseBodyPath: 'data[0].url',
      );

      expect(config.model, 'cogview-3-plus');
      expect(config.stream, false);
      expect(config.apiPath, '/images/generations');
      expect(config.requestBodyTemplate,
          '{"model":"\$model","prompt":"\$prompt"}');
      expect(config.responseBodyPath, 'data[0].url');
      expect(config.isEmpty, false);
    });

    test('isEmpty should return true for empty string fields', () {
      const config = ModelRouteConfig(
        provider: '',
        model: '',
        apiBase: '',
        apiKey: '',
      );
      expect(config.isEmpty, true);
    });

    test('isEmpty should return false if stream is set', () {
      const config = ModelRouteConfig(stream: false);
      expect(config.isEmpty, false);
    });

    test('isEmpty should return false if apiPath is set', () {
      const config = ModelRouteConfig(apiPath: '/images/generations');
      expect(config.isEmpty, false);
    });

    test('isEmpty should return false if requestBodyTemplate is set', () {
      const config = ModelRouteConfig(requestBodyTemplate: '{"model":"\$model"}');
      expect(config.isEmpty, false);
    });

    test('isEmpty should return false if responseBodyPath is set', () {
      const config = ModelRouteConfig(responseBodyPath: 'data[0].url');
      expect(config.isEmpty, false);
    });

    test('isEmpty should return true for empty new fields', () {
      const config = ModelRouteConfig(
        apiPath: '',
        requestBodyTemplate: '',
        responseBodyPath: '',
      );
      expect(config.isEmpty, true);
    });

    test('isEmpty should return false if any field is non-empty', () {
      const config = ModelRouteConfig(model: 'gpt-4');
      expect(config.isEmpty, false);
    });

    test('toJson should only include non-empty fields', () {
      const config = ModelRouteConfig(
        provider: 'openai',
        model: 'gpt-4o',
      );

      final json = config.toJson();

      expect(json['provider'], 'openai');
      expect(json['model'], 'gpt-4o');
      expect(json.containsKey('api_base'), false);
      expect(json.containsKey('api_key'), false);
      expect(json.containsKey('stream'), false);
      expect(json.containsKey('api_path'), false);
      expect(json.containsKey('request_body_template'), false);
      expect(json.containsKey('response_body_path'), false);
    });

    test('toJson should include new non-SSE fields', () {
      const config = ModelRouteConfig(
        model: 'cogview-3-plus',
        stream: false,
        apiPath: '/images/generations',
        requestBodyTemplate: '{"model":"\$model","prompt":"\$prompt"}',
        responseBodyPath: 'data[0].url',
      );

      final json = config.toJson();

      expect(json['model'], 'cogview-3-plus');
      expect(json['stream'], false);
      expect(json['api_path'], '/images/generations');
      expect(json['request_body_template'],
          '{"model":"\$model","prompt":"\$prompt"}');
      expect(json['response_body_path'], 'data[0].url');
    });

    test('toJson should return empty map for empty config', () {
      const config = ModelRouteConfig();
      expect(config.toJson(), isEmpty);
    });

    test('fromJson should parse correctly', () {
      final json = {
        'provider': 'claude',
        'model': 'claude-sonnet-4-20250514',
        'api_base': 'https://api.anthropic.com/v1',
        'api_key': 'sk-ant-test',
      };

      final config = ModelRouteConfig.fromJson(json);

      expect(config.provider, 'claude');
      expect(config.model, 'claude-sonnet-4-20250514');
      expect(config.apiBase, 'https://api.anthropic.com/v1');
      expect(config.apiKey, 'sk-ant-test');
    });

    test('fromJson should parse new non-SSE fields', () {
      final json = {
        'model': 'cogview-3-plus',
        'stream': false,
        'api_path': '/images/generations',
        'request_body_template': '{"model":"\$model","prompt":"\$prompt"}',
        'response_body_path': 'data[0].url',
      };

      final config = ModelRouteConfig.fromJson(json);

      expect(config.stream, false);
      expect(config.apiPath, '/images/generations');
      expect(config.requestBodyTemplate,
          '{"model":"\$model","prompt":"\$prompt"}');
      expect(config.responseBodyPath, 'data[0].url');
    });

    test('fromJson should handle missing fields', () {
      final config = ModelRouteConfig.fromJson({});

      expect(config.provider, isNull);
      expect(config.model, isNull);
      expect(config.stream, isNull);
      expect(config.apiPath, isNull);
      expect(config.requestBodyTemplate, isNull);
      expect(config.responseBodyPath, isNull);
    });

    test('roundtrip JSON with new fields', () {
      const original = ModelRouteConfig(
        provider: 'glm',
        model: 'cogview-3-plus',
        stream: false,
        apiPath: '/images/generations',
        requestBodyTemplate: '{"model":"\$model","prompt":"\$prompt"}',
        responseBodyPath: 'data[0].url',
      );

      final json = original.toJson();
      final restored = ModelRouteConfig.fromJson(json);

      expect(restored.provider, 'glm');
      expect(restored.model, 'cogview-3-plus');
      expect(restored.stream, false);
      expect(restored.apiPath, '/images/generations');
      expect(restored.requestBodyTemplate, original.requestBodyTemplate);
      expect(restored.responseBodyPath, 'data[0].url');
    });
  });

  group('ResolvedModelConfig Tests', () {
    test('should create with all required fields', () {
      const config = ResolvedModelConfig(
        providerType: 'openai',
        model: 'gpt-4o',
        apiBase: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
      );

      expect(config.providerType, 'openai');
      expect(config.model, 'gpt-4o');
      expect(config.apiBase, 'https://api.openai.com/v1');
      expect(config.apiKey, 'sk-test');
    });

    test('should default stream to true', () {
      const config = ResolvedModelConfig(
        providerType: 'openai',
        model: 'gpt-4o',
        apiBase: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
      );

      expect(config.stream, true);
      expect(config.apiPath, isNull);
      expect(config.requestBodyTemplate, isNull);
      expect(config.responseBodyPath, isNull);
    });

    test('should accept explicit new field values', () {
      const config = ResolvedModelConfig(
        providerType: 'glm',
        model: 'cogview-3-plus',
        apiBase: 'https://open.bigmodel.cn/api/paas/v4',
        apiKey: 'sk-test',
        stream: false,
        apiPath: '/images/generations',
        requestBodyTemplate: '{"model":"\$model","prompt":"\$prompt"}',
        responseBodyPath: 'data[0].url',
      );

      expect(config.stream, false);
      expect(config.apiPath, '/images/generations');
      expect(config.requestBodyTemplate,
          '{"model":"\$model","prompt":"\$prompt"}');
      expect(config.responseBodyPath, 'data[0].url');
    });
  });

  group('ModelRoutingConfig Tests', () {
    test('default config should be empty', () {
      const config = ModelRoutingConfig();

      expect(config.isEmpty, true);
      expect(config.routes, isEmpty);
    });

    test('isEmpty should be true when all routes are empty', () {
      final config = ModelRoutingConfig(routes: {
        ModalityType.text: const ModelRouteConfig(),
        ModalityType.image: const ModelRouteConfig(provider: ''),
      });

      expect(config.isEmpty, true);
    });

    test('isEmpty should be false when at least one route has data', () {
      final config = ModelRoutingConfig(routes: {
        ModalityType.image: const ModelRouteConfig(model: 'gpt-4o'),
      });

      expect(config.isEmpty, false);
    });

    group('resolve', () {
      test('should use route values when set', () {
        final config = ModelRoutingConfig(routes: {
          ModalityType.image: const ModelRouteConfig(
            provider: 'openai',
            model: 'gpt-4o',
            apiBase: 'https://api.openai.com/v1',
            apiKey: 'sk-image',
          ),
        });

        final resolved = config.resolve(
          ModalityType.image,
          fallbackProvider: 'claude',
          fallbackModel: 'claude-sonnet',
          fallbackApiBase: 'https://api.anthropic.com',
          fallbackApiKey: 'sk-fallback',
        );

        expect(resolved.providerType, 'openai');
        expect(resolved.model, 'gpt-4o');
        expect(resolved.apiBase, 'https://api.openai.com/v1');
        expect(resolved.apiKey, 'sk-image');
      });

      test('should fall back to defaults when route not configured', () {
        const config = ModelRoutingConfig();

        final resolved = config.resolve(
          ModalityType.text,
          fallbackProvider: 'claude',
          fallbackModel: 'claude-sonnet',
          fallbackApiBase: 'https://api.anthropic.com',
          fallbackApiKey: 'sk-fallback',
        );

        expect(resolved.providerType, 'claude');
        expect(resolved.model, 'claude-sonnet');
        expect(resolved.apiBase, 'https://api.anthropic.com');
        expect(resolved.apiKey, 'sk-fallback');
      });

      test('should fall back per-field when route has partial config', () {
        final config = ModelRoutingConfig(routes: {
          ModalityType.image: const ModelRouteConfig(
            provider: 'openai',
            model: 'gpt-4o',
            // apiBase and apiKey not set
          ),
        });

        final resolved = config.resolve(
          ModalityType.image,
          fallbackProvider: 'claude',
          fallbackModel: 'claude-sonnet',
          fallbackApiBase: 'https://api.anthropic.com/v1',
          fallbackApiKey: 'sk-ant-fallback',
        );

        expect(resolved.providerType, 'openai');
        expect(resolved.model, 'gpt-4o');
        expect(resolved.apiBase, 'https://api.anthropic.com/v1'); // fallback
        expect(resolved.apiKey, 'sk-ant-fallback'); // fallback
      });

      test('should fall back when route field is empty string', () {
        final config = ModelRoutingConfig(routes: {
          ModalityType.audio: const ModelRouteConfig(
            provider: '',
            model: '',
          ),
        });

        final resolved = config.resolve(
          ModalityType.audio,
          fallbackProvider: 'openai',
          fallbackModel: 'whisper-1',
          fallbackApiBase: 'https://api.openai.com/v1',
          fallbackApiKey: 'sk-key',
        );

        expect(resolved.providerType, 'openai');
        expect(resolved.model, 'whisper-1');
      });

      test('should pass through new fields from route', () {
        final config = ModelRoutingConfig(routes: {
          ModalityType.image: const ModelRouteConfig(
            model: 'cogview-3-plus',
            stream: false,
            apiPath: '/images/generations',
            requestBodyTemplate: '{"model":"\$model","prompt":"\$prompt"}',
            responseBodyPath: 'data[0].url',
          ),
        });

        final resolved = config.resolve(
          ModalityType.image,
          fallbackProvider: 'glm',
          fallbackModel: 'glm-4',
          fallbackApiBase: 'https://open.bigmodel.cn/api/paas/v4',
          fallbackApiKey: 'sk-key',
        );

        expect(resolved.stream, false);
        expect(resolved.apiPath, '/images/generations');
        expect(resolved.requestBodyTemplate,
            '{"model":"\$model","prompt":"\$prompt"}');
        expect(resolved.responseBodyPath, 'data[0].url');
        expect(resolved.model, 'cogview-3-plus');
      });

      test('should default stream to true when route has no stream set', () {
        final config = ModelRoutingConfig(routes: {
          ModalityType.text: const ModelRouteConfig(model: 'gpt-4'),
        });

        final resolved = config.resolve(
          ModalityType.text,
          fallbackProvider: 'openai',
          fallbackModel: 'gpt-3.5',
          fallbackApiBase: 'https://api.openai.com/v1',
          fallbackApiKey: 'sk-key',
        );

        expect(resolved.stream, true);
        expect(resolved.apiPath, isNull);
        expect(resolved.requestBodyTemplate, isNull);
        expect(resolved.responseBodyPath, isNull);
      });
    });

    group('JSON serialization', () {
      test('toJson should only include non-empty routes', () {
        final config = ModelRoutingConfig(routes: {
          ModalityType.text: const ModelRouteConfig(model: 'gpt-4o'),
          ModalityType.image: const ModelRouteConfig(), // empty, should be omitted
        });

        final json = config.toJson();

        expect(json.containsKey('text'), true);
        expect(json['text']['model'], 'gpt-4o');
        expect(json.containsKey('image'), false);
      });

      test('toJson should return empty map for empty config', () {
        const config = ModelRoutingConfig();
        expect(config.toJson(), isEmpty);
      });

      test('fromJson with null should return empty config', () {
        final config = ModelRoutingConfig.fromJson(null);
        expect(config.isEmpty, true);
      });

      test('fromJson with empty map should return empty config', () {
        final config = ModelRoutingConfig.fromJson({});
        expect(config.isEmpty, true);
      });

      test('fromJson should parse routes correctly', () {
        final json = <String, dynamic>{
          'text': <String, dynamic>{'provider': 'openai', 'model': 'gpt-4'},
          'image': <String, dynamic>{'provider': 'openai', 'model': 'gpt-4o', 'api_key': 'sk-img'},
          'video': <String, dynamic>{}, // empty route, should be skipped
        };

        final config = ModelRoutingConfig.fromJson(json);

        expect(config.routes.containsKey(ModalityType.text), true);
        expect(config.routes[ModalityType.text]!.model, 'gpt-4');
        expect(config.routes.containsKey(ModalityType.image), true);
        expect(config.routes[ModalityType.image]!.apiKey, 'sk-img');
        // Empty route should not be included
        expect(config.routes.containsKey(ModalityType.video), false);
      });

      test('fromJson should parse routes with new fields', () {
        final json = <String, dynamic>{
          'image': <String, dynamic>{
            'model': 'cogview-3-plus',
            'stream': false,
            'api_path': '/images/generations',
            'request_body_template': '{"model":"\$model","prompt":"\$prompt"}',
            'response_body_path': 'data[0].url',
          },
        };

        final config = ModelRoutingConfig.fromJson(json);

        expect(config.routes.containsKey(ModalityType.image), true);
        final route = config.routes[ModalityType.image]!;
        expect(route.stream, false);
        expect(route.apiPath, '/images/generations');
        expect(route.responseBodyPath, 'data[0].url');
      });

      test('roundtrip JSON serialization should preserve data', () {
        final original = ModelRoutingConfig(routes: {
          ModalityType.text: const ModelRouteConfig(
            provider: 'openai',
            model: 'gpt-4',
          ),
          ModalityType.audio: const ModelRouteConfig(
            provider: 'openai',
            model: 'whisper-1',
            apiBase: 'https://api.openai.com/v1',
          ),
        });

        final json = original.toJson();
        final restored = ModelRoutingConfig.fromJson(json);

        expect(restored.routes.length, 2);
        expect(restored.routes[ModalityType.text]!.provider, 'openai');
        expect(restored.routes[ModalityType.text]!.model, 'gpt-4');
        expect(restored.routes[ModalityType.audio]!.model, 'whisper-1');
      });

      test('roundtrip JSON with new non-SSE fields', () {
        final original = ModelRoutingConfig(routes: {
          ModalityType.image: const ModelRouteConfig(
            provider: 'glm',
            model: 'cogview-3-plus',
            stream: false,
            apiPath: '/images/generations',
            requestBodyTemplate: '{"model":"\$model","prompt":"\$prompt"}',
            responseBodyPath: 'data[0].url',
          ),
        });

        final json = original.toJson();
        final restored = ModelRoutingConfig.fromJson(json);

        expect(restored.routes.length, 1);
        final route = restored.routes[ModalityType.image]!;
        expect(route.provider, 'glm');
        expect(route.model, 'cogview-3-plus');
        expect(route.stream, false);
        expect(route.apiPath, '/images/generations');
        expect(route.requestBodyTemplate,
            '{"model":"\$model","prompt":"\$prompt"}');
        expect(route.responseBodyPath, 'data[0].url');
      });
    });

    group('detectModality', () {
      test('should return text for empty attachments', () {
        expect(
          ModelRoutingConfig.detectModality([]),
          ModalityType.text,
        );
      });

      test('should detect video with highest priority', () {
        expect(
          ModelRoutingConfig.detectModality(['image', 'video', 'audio']),
          ModalityType.video,
        );
      });

      test('should detect audio when no video present', () {
        expect(
          ModelRoutingConfig.detectModality(['image', 'audio']),
          ModalityType.audio,
        );
      });

      test('should detect image when no video/audio present', () {
        expect(
          ModelRoutingConfig.detectModality(['image']),
          ModalityType.image,
        );
      });

      test('should default to text for unknown types', () {
        expect(
          ModelRoutingConfig.detectModality(['document', 'spreadsheet']),
          ModalityType.text,
        );
      });

      test('priority order: video > audio > image > text', () {
        // Only video
        expect(
          ModelRoutingConfig.detectModality(['video']),
          ModalityType.video,
        );
        // Audio + image (no video)
        expect(
          ModelRoutingConfig.detectModality(['audio', 'image']),
          ModalityType.audio,
        );
        // Only image
        expect(
          ModelRoutingConfig.detectModality(['image', 'document']),
          ModalityType.image,
        );
      });
    });
  });

  group('resolveJsonPath Tests', () {
    test('should resolve simple key', () {
      final json = {'name': 'test'};
      expect(resolveJsonPath(json, 'name'), 'test');
    });

    test('should resolve nested key', () {
      final json = {
        'message': {'content': 'hello'}
      };
      expect(resolveJsonPath(json, 'message.content'), 'hello');
    });

    test('should resolve array index', () {
      final json = {
        'data': [
          {'url': 'https://example.com/img.png'}
        ]
      };
      expect(resolveJsonPath(json, 'data[0].url'),
          'https://example.com/img.png');
    });

    test('should resolve deep nesting with array', () {
      final json = {
        'choices': [
          {
            'message': {'content': 'response text'}
          }
        ]
      };
      expect(resolveJsonPath(json, 'choices[0].message.content'),
          'response text');
    });

    test('should return null for missing key', () {
      final json = {'name': 'test'};
      expect(resolveJsonPath(json, 'missing'), isNull);
    });

    test('should return null for out-of-bounds index', () {
      final json = {
        'data': [
          {'url': 'first'}
        ]
      };
      expect(resolveJsonPath(json, 'data[5].url'), isNull);
    });

    test('should return null for path into non-map', () {
      final json = {'name': 'test'};
      expect(resolveJsonPath(json, 'name.sub'), isNull);
    });

    test('should return null when json is null', () {
      expect(resolveJsonPath(null, 'key'), isNull);
    });

    test('should resolve bare array index', () {
      final json = [
        'first',
        'second',
        'third',
      ];
      expect(resolveJsonPath(json, '[1]'), 'second');
    });

    test('should resolve multiple array indices', () {
      final json = {
        'matrix': [
          [1, 2, 3],
          [4, 5, 6],
        ]
      };
      expect(resolveJsonPath(json, 'matrix[1][2]'), 6);
    });

    test('should resolve numeric value', () {
      final json = {
        'data': [
          {'count': 42}
        ]
      };
      expect(resolveJsonPath(json, 'data[0].count'), 42);
    });
  });

  group('CustomModality Tests', () {
    test('should create with required fields', () {
      const cm = CustomModality(
        key: 'image_gen',
        label: 'Image Generation',
        description: 'User wants to generate images',
        route: ModelRouteConfig(model: 'cogview-3-plus'),
      );

      expect(cm.key, 'image_gen');
      expect(cm.label, 'Image Generation');
      expect(cm.description, 'User wants to generate images');
      expect(cm.route.model, 'cogview-3-plus');
    });

    test('isEmpty should return true when key is empty', () {
      const cm = CustomModality(
        key: '',
        label: 'Test',
        description: 'Test',
        route: ModelRouteConfig(model: 'test'),
      );
      expect(cm.isEmpty, true);
    });

    test('isEmpty should return true when route is empty', () {
      const cm = CustomModality(
        key: 'test',
        label: 'Test',
        description: 'Test',
        route: ModelRouteConfig(),
      );
      expect(cm.isEmpty, true);
    });

    test('isEmpty should return false when key and route are non-empty', () {
      const cm = CustomModality(
        key: 'image_gen',
        label: 'Image Generation',
        description: 'Generate images',
        route: ModelRouteConfig(model: 'cogview-3-plus'),
      );
      expect(cm.isEmpty, false);
    });

    test('toJson should include all fields', () {
      const cm = CustomModality(
        key: 'image_gen',
        label: 'Image Generation',
        description: 'Generate images',
        route: ModelRouteConfig(
          model: 'cogview-3-plus',
          stream: false,
          apiPath: '/images/generations',
        ),
      );

      final json = cm.toJson();

      expect(json['key'], 'image_gen');
      expect(json['label'], 'Image Generation');
      expect(json['description'], 'Generate images');
      expect(json['route'], isA<Map>());
      expect(json['route']['model'], 'cogview-3-plus');
      expect(json['route']['stream'], false);
      expect(json['route']['api_path'], '/images/generations');
    });

    test('fromJson should parse correctly', () {
      final json = {
        'key': 'tts',
        'label': 'Text to Speech',
        'description': 'Convert text to audio',
        'route': {
          'model': 'tts-1',
          'stream': false,
        },
      };

      final cm = CustomModality.fromJson(json);

      expect(cm.key, 'tts');
      expect(cm.label, 'Text to Speech');
      expect(cm.description, 'Convert text to audio');
      expect(cm.route.model, 'tts-1');
      expect(cm.route.stream, false);
    });

    test('fromJson should handle missing fields', () {
      final cm = CustomModality.fromJson({});

      expect(cm.key, '');
      expect(cm.label, '');
      expect(cm.description, '');
      expect(cm.route.isEmpty, true);
    });

    test('roundtrip JSON serialization', () {
      const original = CustomModality(
        key: 'video_gen',
        label: 'Video Generation',
        description: 'Generate videos from text',
        route: ModelRouteConfig(
          model: 'sora-1',
          stream: false,
          apiPath: '/videos/generations',
          requestBodyTemplate: '{"model":"\$model","prompt":"\$prompt"}',
          responseBodyPath: 'data[0].url',
        ),
      );

      final json = original.toJson();
      final restored = CustomModality.fromJson(json);

      expect(restored.key, 'video_gen');
      expect(restored.label, 'Video Generation');
      expect(restored.description, 'Generate videos from text');
      expect(restored.route.model, 'sora-1');
      expect(restored.route.stream, false);
      expect(restored.route.apiPath, '/videos/generations');
      expect(restored.route.requestBodyTemplate, original.route.requestBodyTemplate);
      expect(restored.route.responseBodyPath, 'data[0].url');
    });
  });

  group('ModelRoutingConfig with customModalities', () {
    test('isEmpty should be true when only empty custom modalities', () {
      const config = ModelRoutingConfig(
        customModalities: [
          CustomModality(
            key: '',
            label: '',
            description: '',
            route: ModelRouteConfig(),
          ),
        ],
      );
      expect(config.isEmpty, true);
    });

    test('isEmpty should be false when non-empty custom modality exists', () {
      const config = ModelRoutingConfig(
        customModalities: [
          CustomModality(
            key: 'image_gen',
            label: 'Image Gen',
            description: 'Generate images',
            route: ModelRouteConfig(model: 'cogview-3-plus'),
          ),
        ],
      );
      expect(config.isEmpty, false);
    });

    test('needsIntentClassification should be false for empty config', () {
      const config = ModelRoutingConfig();
      expect(config.needsIntentClassification, false);
    });

    test('needsIntentClassification should be false for empty custom modalities', () {
      const config = ModelRoutingConfig(
        customModalities: [
          CustomModality(key: '', label: '', description: '', route: ModelRouteConfig()),
        ],
      );
      expect(config.needsIntentClassification, false);
    });

    test('needsIntentClassification should be true when valid custom modality exists', () {
      const config = ModelRoutingConfig(
        customModalities: [
          CustomModality(
            key: 'image_gen',
            label: 'Image Gen',
            description: 'Generate images',
            route: ModelRouteConfig(model: 'cogview-3-plus'),
          ),
        ],
      );
      expect(config.needsIntentClassification, true);
    });

    group('resolveCustom', () {
      test('should resolve with full config', () {
        const config = ModelRoutingConfig(
          customModalities: [
            CustomModality(
              key: 'image_gen',
              label: 'Image Gen',
              description: 'Generate images',
              route: ModelRouteConfig(
                provider: 'glm',
                model: 'cogview-3-plus',
                apiBase: 'https://open.bigmodel.cn/api/paas/v4',
                apiKey: 'sk-custom',
                stream: false,
                apiPath: '/images/generations',
              ),
            ),
          ],
        );

        final resolved = config.resolveCustom(
          'image_gen',
          fallbackProvider: 'openai',
          fallbackModel: 'gpt-4',
          fallbackApiBase: 'https://api.openai.com/v1',
          fallbackApiKey: 'sk-fallback',
        );

        expect(resolved.providerType, 'glm');
        expect(resolved.model, 'cogview-3-plus');
        expect(resolved.apiBase, 'https://open.bigmodel.cn/api/paas/v4');
        expect(resolved.apiKey, 'sk-custom');
        expect(resolved.stream, false);
        expect(resolved.apiPath, '/images/generations');
      });

      test('should fall back per-field when custom modality has partial config', () {
        const config = ModelRoutingConfig(
          customModalities: [
            CustomModality(
              key: 'image_gen',
              label: 'Image Gen',
              description: 'Generate images',
              route: ModelRouteConfig(
                model: 'cogview-3-plus',
                stream: false,
              ),
            ),
          ],
        );

        final resolved = config.resolveCustom(
          'image_gen',
          fallbackProvider: 'glm',
          fallbackModel: 'glm-4',
          fallbackApiBase: 'https://open.bigmodel.cn/api/paas/v4',
          fallbackApiKey: 'sk-fallback',
        );

        expect(resolved.providerType, 'glm');
        expect(resolved.model, 'cogview-3-plus');
        expect(resolved.apiBase, 'https://open.bigmodel.cn/api/paas/v4');
        expect(resolved.apiKey, 'sk-fallback');
        expect(resolved.stream, false);
      });

      test('should fall back to defaults when key not found', () {
        const config = ModelRoutingConfig(
          customModalities: [
            CustomModality(
              key: 'image_gen',
              label: 'Image Gen',
              description: 'Generate images',
              route: ModelRouteConfig(model: 'cogview-3-plus'),
            ),
          ],
        );

        final resolved = config.resolveCustom(
          'nonexistent',
          fallbackProvider: 'openai',
          fallbackModel: 'gpt-4',
          fallbackApiBase: 'https://api.openai.com/v1',
          fallbackApiKey: 'sk-fallback',
        );

        expect(resolved.providerType, 'openai');
        expect(resolved.model, 'gpt-4');
        expect(resolved.apiBase, 'https://api.openai.com/v1');
        expect(resolved.apiKey, 'sk-fallback');
      });
    });

    group('JSON serialization with customModalities', () {
      test('toJson should include custom_modalities', () {
        const config = ModelRoutingConfig(
          customModalities: [
            CustomModality(
              key: 'image_gen',
              label: 'Image Gen',
              description: 'Generate images',
              route: ModelRouteConfig(model: 'cogview-3-plus'),
            ),
          ],
        );

        final json = config.toJson();

        expect(json.containsKey('custom_modalities'), true);
        expect(json['custom_modalities'], isA<List>());
        expect((json['custom_modalities'] as List).length, 1);
        expect((json['custom_modalities'] as List)[0]['key'], 'image_gen');
      });

      test('toJson should omit custom_modalities when all are empty', () {
        const config = ModelRoutingConfig(
          customModalities: [
            CustomModality(key: '', label: '', description: '', route: ModelRouteConfig()),
          ],
        );

        final json = config.toJson();
        expect(json.containsKey('custom_modalities'), false);
      });

      test('fromJson should parse custom_modalities', () {
        final json = <String, dynamic>{
          'text': <String, dynamic>{'model': 'gpt-4'},
          'custom_modalities': [
            {
              'key': 'tts',
              'label': 'Text to Speech',
              'description': 'Convert text to audio',
              'route': {'model': 'tts-1', 'stream': false},
            },
          ],
        };

        final config = ModelRoutingConfig.fromJson(json);

        expect(config.routes.containsKey(ModalityType.text), true);
        expect(config.customModalities.length, 1);
        expect(config.customModalities[0].key, 'tts');
        expect(config.customModalities[0].route.model, 'tts-1');
      });

      test('fromJson should handle missing custom_modalities', () {
        final json = <String, dynamic>{
          'text': <String, dynamic>{'model': 'gpt-4'},
        };

        final config = ModelRoutingConfig.fromJson(json);
        expect(config.customModalities, isEmpty);
      });

      test('roundtrip JSON with routes and custom modalities', () {
        final original = ModelRoutingConfig(
          routes: {
            ModalityType.text: const ModelRouteConfig(model: 'gpt-4'),
          },
          customModalities: const [
            CustomModality(
              key: 'image_gen',
              label: 'Image Generation',
              description: 'Generate images from text',
              route: ModelRouteConfig(
                model: 'cogview-3-plus',
                stream: false,
                apiPath: '/images/generations',
                requestBodyTemplate: '{"model":"\$model","prompt":"\$prompt"}',
                responseBodyPath: 'data[0].url',
              ),
            ),
            CustomModality(
              key: 'tts',
              label: 'Text to Speech',
              description: 'Convert text to audio',
              route: ModelRouteConfig(
                model: 'tts-1',
                stream: false,
              ),
            ),
          ],
        );

        final json = original.toJson();
        final restored = ModelRoutingConfig.fromJson(json);

        expect(restored.routes.length, 1);
        expect(restored.routes[ModalityType.text]!.model, 'gpt-4');
        expect(restored.customModalities.length, 2);
        expect(restored.customModalities[0].key, 'image_gen');
        expect(restored.customModalities[0].route.model, 'cogview-3-plus');
        expect(restored.customModalities[0].route.stream, false);
        expect(restored.customModalities[0].route.apiPath, '/images/generations');
        expect(restored.customModalities[1].key, 'tts');
        expect(restored.customModalities[1].route.model, 'tts-1');
        expect(restored.needsIntentClassification, true);
      });
    });
  });
}
