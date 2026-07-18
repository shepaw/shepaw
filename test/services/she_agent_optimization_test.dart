import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/local_llm_agent_service.dart';
import 'package:shepaw/services/messaging/local_llm_handler.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  group('LocalLLMAgentService.isRetryableLlmError', () {
    test('connection-class errors are retryable', () {
      expect(LocalLLMAgentService.isRetryableLlmError(const SocketException('x')), isTrue);
      expect(LocalLLMAgentService.isRetryableLlmError(TimeoutException('x')), isTrue);
      expect(LocalLLMAgentService.isRetryableLlmError(const HandshakeException('x')), isTrue);
      expect(LocalLLMAgentService.isRetryableLlmError(const HttpException('x')), isTrue);
    });

    test('4xx API errors are not retryable (multimodal-fallback contract)', () {
      expect(
        LocalLLMAgentService.isRetryableLlmError(Exception('LLM API error (400): bad')),
        isFalse,
      );
      expect(
        LocalLLMAgentService.isRetryableLlmError(Exception('LLM API error (401): nope')),
        isFalse,
      );
    });

    test('arbitrary errors are not retryable', () {
      expect(LocalLLMAgentService.isRetryableLlmError(StateError('x')), isFalse);
      expect(LocalLLMAgentService.isRetryableLlmError(Exception('x')), isFalse);
    });
  });

  group('SheService.buildSessionEndBlock (single-source memory)', () {
    test('self-reflections go to she_memory.db via memory.append', () {
      final block = SheService.instance.buildSessionEndBlock();
      expect(block, contains('memory.append --key self_notes'));
      expect(block, isNot(contains('--type self --soul')));
    });

    test('user impression still routed to cognition-write', () {
      final block = SheService.instance.buildSessionEndBlock();
      expect(block, contains('--type user --field impression'));
    });
  });

  group('SheService.truncateTail', () {
    test('returns text unchanged when within budget', () {
      expect(SheService.truncateTail('hello', 10), 'hello');
      expect(SheService.truncateTail('hello', 5), 'hello');
    });

    test('keeps the tail and prefixes an omission note when over budget', () {
      final text = 'a' * 100 + 'b' * 100;
      final out = SheService.truncateTail(text, 50);
      expect(out, startsWith('[older entries omitted]\n'));
      expect(out.length, '[older entries omitted]\n'.length + 50);
      expect(out, endsWith('b' * 50));
    });
  });

  group('LocalLLMHelpers.truncateToolResult', () {
    test('returns result unchanged when within budget', () {
      expect(LocalLLMHelpers.truncateToolResult('short', 'id-1'), 'short');
    });

    test('truncates long results and points to get_tool_result', () {
      final long = 'x' * 9000;
      final out = LocalLLMHelpers.truncateToolResult(long, 'call-42');
      expect(out.length, lessThan(long.length + 200));
      expect(out, startsWith('x' * 8000));
      expect(out, contains('9000 chars total'));
      expect(out, contains('get_tool_result'));
      expect(out, contains('call-42'));
    });

    test('respects a custom maxChars', () {
      final out = LocalLLMHelpers.truncateToolResult('y' * 100, 'id-2', maxChars: 10);
      expect(out, startsWith('y' * 10));
      expect(out, contains('100 chars total'));
    });
  });

  group('LocalLLMHelpers get_tool_result tool definitions', () {
    // The 1:1 tool loop intercepts calls by this exact name and the truncation
    // hint tells the model to call it — the exposed definitions must match.
    test('OpenAI definition matches the loop handler contract', () {
      final def = LocalLLMHelpers.getToolResultOpenAI();
      expect(def['type'], 'function');
      final fn = def['function'] as Map<String, dynamic>;
      expect(fn['name'], LocalLLMHelpers.kGetToolResult);
      final params = fn['parameters'] as Map<String, dynamic>;
      expect(params['required'], contains('tool_call_id'));
    });

    test('Claude definition matches the loop handler contract', () {
      final def = LocalLLMHelpers.getToolResultClaude();
      expect(def['name'], LocalLLMHelpers.kGetToolResult);
      final schema = def['input_schema'] as Map<String, dynamic>;
      expect(schema['required'], contains('tool_call_id'));
    });
  });
}
