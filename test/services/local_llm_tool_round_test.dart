import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/llm_stream_event.dart';
import 'package:shepaw/services/messaging/local_llm_handler.dart';

void main() {
  group('LocalLLMHelpers.ensureToolResultsForAssistant', () {
    test('pads missing OpenAI tool results (form + group_finish)', () {
      final raw = {
        'role': 'assistant',
        'content': '摸底回来了',
        'tool_calls': [
          {
            'id': 'call_form',
            'type': 'function',
            'function': {'name': 'form', 'arguments': '{}'},
          },
          {
            'id': 'call_finish',
            'type': 'function',
            'function': {
              'name': 'group_finish',
              'arguments': '{"action":"pause"}',
            },
          },
        ],
      };
      final results = <Map<String, dynamic>>[
        {
          'tool_call_id': 'call_finish',
          'name': 'group_finish',
          'result': '{"ok":true,"action":"pause"}',
        },
      ];

      LocalLLMHelpers.ensureToolResultsForAssistant(
        rawAssistant: raw,
        toolResults: results,
        isClaude: false,
      );

      expect(results.length, 2);
      expect(
        results.map((r) => r['tool_call_id']),
        containsAll(['call_form', 'call_finish']),
      );
      final form = results.firstWhere((r) => r['tool_call_id'] == 'call_form');
      expect(form['name'], 'form');
      expect(form['result'], LocalLLMHelpers.missingToolResultStub);

      final messages = <Map<String, dynamic>>[];
      LocalLLMHelpers.appendToolRoundOpenAI(
        messages,
        raw,
        const <LLMToolCallEvent>[],
        results,
      );
      expect(messages[0]['tool_calls'], hasLength(2));
      final toolMsgs = messages.where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs, hasLength(2));
      expect(
        toolMsgs.map((m) => m['tool_call_id']),
        containsAll(['call_form', 'call_finish']),
      );
    });

    test('pads missing Claude tool_use results', () {
      final raw = {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'hi'},
          {'type': 'tool_use', 'id': 'tu_form', 'name': 'form', 'input': {}},
          {
            'type': 'tool_use',
            'id': 'tu_finish',
            'name': 'group_finish',
            'input': {'action': 'pause'},
          },
        ],
      };
      final results = <Map<String, dynamic>>[
        {
          'tool_call_id': 'tu_finish',
          'name': 'group_finish',
          'result': '{"ok":true}',
        },
      ];

      LocalLLMHelpers.ensureToolResultsForAssistant(
        rawAssistant: raw,
        toolResults: results,
        isClaude: true,
      );

      expect(results.map((r) => r['tool_call_id']), contains('tu_form'));
      final messages = <Map<String, dynamic>>[];
      LocalLLMHelpers.appendToolRoundClaude(
        messages,
        raw,
        const <LLMToolCallEvent>[],
        results,
      );
      final blocks = messages.last['content'] as List;
      expect(blocks, hasLength(2));
      expect(
        blocks.map((b) => b['tool_use_id']),
        containsAll(['tu_form', 'tu_finish']),
      );
    });

    test('does not duplicate results that already exist', () {
      final raw = {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {'name': 'form', 'arguments': '{}'},
          },
        ],
      };
      final results = <Map<String, dynamic>>[
        {'tool_call_id': 'call_1', 'name': 'form', 'result': '{"ok":true}'},
      ];
      LocalLLMHelpers.ensureToolResultsForAssistant(
        rawAssistant: raw,
        toolResults: results,
        isClaude: false,
      );
      expect(results, hasLength(1));
      expect(results.single['result'], '{"ok":true}');
    });
  });

  group('LocalLLMHelpers.sanitizeAssistantToolCalls', () {
    test('drops OpenAI tool_calls with empty id', () {
      final raw = {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': '',
            'type': 'function',
            'function': {'name': '', 'arguments': ''},
          },
          {
            'id': 'call_ok',
            'type': 'function',
            'function': {'name': 'form', 'arguments': '{}'},
          },
        ],
      };
      final sanitized = LocalLLMHelpers.sanitizeAssistantToolCalls(
        raw,
        isClaude: false,
      );
      expect(sanitized['tool_calls'], hasLength(1));
      expect(sanitized['tool_calls'][0]['id'], 'call_ok');
    });

    test('removes tool_calls key when all ids are empty', () {
      final raw = {
        'role': 'assistant',
        'content': 'hi',
        'tool_calls': [
          {
            'id': '',
            'type': 'function',
            'function': {'name': '', 'arguments': ''},
          },
        ],
      };
      final sanitized = LocalLLMHelpers.sanitizeAssistantToolCalls(
        raw,
        isClaude: false,
      );
      expect(sanitized.containsKey('tool_calls'), isFalse);
    });
  });
}
