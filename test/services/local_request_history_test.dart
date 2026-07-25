import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/llm_stream_event.dart';
import 'package:shepaw/services/messaging/local_llm_handler.dart';
import 'package:shepaw/services/task/task_models.dart';
import 'package:shepaw/services/ui_component_registry.dart';

void main() {
  group('UIComponentRegistry request_history', () {
    test('is tool-callable with parameter schema for local agents', () {
      final def = UIComponentRegistry.instance.components
          .firstWhere((c) => c.name == 'request_history');
      expect(def.isToolCallable, isTrue);
      expect(def.parameterSchema, isNotNull);
      expect(def.parameterSchema!['required'], contains('reason'));

      final openAiNames = UIComponentRegistry.instance
          .openAITools()
          .map((t) => (t['function'] as Map)['name'])
          .toList();
      expect(openAiNames, contains('request_history'));
    });
  });

  group('LocalLLMHelpers.dispatchUiToolCall request_history', () {
    test('normalizes payload and invokes onRequestHistory', () {
      Map<String, dynamic>? captured;
      Map<String, dynamic>? viaCallback;
      final task = ActiveTask(
        taskId: 't1',
        agentId: 'a1',
        agentName: 'A',
        channelId: 'c1',
        userMessageId: 'm1',
        userId: 'u1',
        userName: 'U',
      );
      task.onRequestHistory = (data) => viaCallback = data;

      LocalLLMHelpers.dispatchUiToolCall(
        LLMToolCallEvent(
          id: 'call_1',
          name: 'request_history',
          arguments: {'reason': 'Need earlier context'},
        ),
        task,
        onCaptured: ({
          Map<String, dynamic>? ac,
          Map<String, dynamic>? ss,
          Map<String, dynamic>? ms,
          Map<String, dynamic>? fu,
          Map<String, dynamic>? fd,
          Map<String, dynamic>? mm,
          Map<String, dynamic>? rh,
          bool? fmh,
        }) {
          captured = rh;
        },
      );

      expect(captured, isNotNull);
      expect(viaCallback, isNotNull);
      expect(captured!['reason'], 'Need earlier context');
      expect(captured!['requested_count'], 40);
      expect(captured!['request_id'], isA<String>());
      expect((captured!['request_id'] as String).isNotEmpty, isTrue);
      expect(viaCallback!['reason'], 'Need earlier context');
    });
  });
}
