import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/llm_token_usage.dart';
import 'package:shepaw/models/model_token_pricing.dart';

void main() {
  group('LlmTokenUsage.fromJson', () {
    test('parses OpenAI usage fields', () {
      final u = LlmTokenUsage.fromJson({
        'prompt_tokens': 100,
        'completion_tokens': 50,
      });
      expect(u?.inputTokens, 100);
      expect(u?.outputTokens, 50);
    });

    test('parses Claude usage fields', () {
      final u = LlmTokenUsage.fromJson({
        'input_tokens': 80,
        'output_tokens': 40,
      });
      expect(u?.inputTokens, 80);
      expect(u?.outputTokens, 40);
    });

    test('merge prefers later non-null values', () {
      const a = LlmTokenUsage(inputTokens: 10, outputTokens: 1);
      final b = a.merge(const LlmTokenUsage(outputTokens: 20));
      expect(b.inputTokens, 10);
      expect(b.outputTokens, 20);
    });

    test('returns null for empty map', () {
      expect(LlmTokenUsage.fromJson(<String, dynamic>{}), isNull);
      expect(LlmTokenUsage.fromJson(null), isNull);
    });
  });

  group('LlmTokenUsage.plus', () {
    test('sums across rounds', () {
      const a = LlmTokenUsage(inputTokens: 1000, outputTokens: 100);
      final b = a.plus(const LlmTokenUsage(inputTokens: 2000, outputTokens: 50));
      expect(b.inputTokens, 3000);
      expect(b.outputTokens, 150);
    });

    test('treats null side as zero when other side is present', () {
      const a = LlmTokenUsage(inputTokens: 10);
      final b = a.plus(const LlmTokenUsage(outputTokens: 5));
      expect(b.inputTokens, 10);
      expect(b.outputTokens, 5);
    });

    test('null other is a no-op', () {
      const a = LlmTokenUsage(inputTokens: 7, outputTokens: 3);
      expect(a.plus(null).inputTokens, 7);
      expect(a.plus(null).outputTokens, 3);
    });
  });

  group('LlmTokenUsage metadata round-trip', () {
    test('toJson omits null fields', () {
      expect(
        const LlmTokenUsage(inputTokens: 12).toJson(),
        {'input_tokens': 12},
      );
      expect(
        const LlmTokenUsage(inputTokens: 1, outputTokens: 2).toJson(),
        {'input_tokens': 1, 'output_tokens': 2},
      );
    });

    test('fromMetadata reads nested token_usage key', () {
      final u = LlmTokenUsage.fromMetadata({
        LlmTokenUsage.metadataKey: {
          'input_tokens': 123,
          'output_tokens': 45,
        },
      });
      expect(u?.inputTokens, 123);
      expect(u?.outputTokens, 45);
    });

    test('fromMetadata returns null when absent', () {
      expect(LlmTokenUsage.fromMetadata(null), isNull);
      expect(LlmTokenUsage.fromMetadata({'trace_id': 'abc'}), isNull);
    });
  });

  group('LlmTokenUsage.compactLabel / formatCount', () {
    test('formats compact bubble label', () {
      expect(
        const LlmTokenUsage(inputTokens: 12345, outputTokens: 456).compactLabel,
        '↑12.3k ↓456',
      );
      expect(const LlmTokenUsage().compactLabel, isNull);
      expect(
        const LlmTokenUsage(inputTokens: 0, outputTokens: 0).compactLabel,
        isNull,
      );
    });

    test('formatCount thresholds', () {
      expect(LlmTokenUsage.formatCount(999), '999');
      expect(LlmTokenUsage.formatCount(1000), '1k');
      expect(LlmTokenUsage.formatCount(1234), '1.2k');
      expect(LlmTokenUsage.formatCount(12345), '12.3k');
      expect(LlmTokenUsage.formatCount(123456), '123k');
      expect(LlmTokenUsage.formatCount(2345678), '2.3M');
    });
  });

  group('ModelTokenPricing', () {
    test('matches model substrings and estimates cost', () {
      final p = ModelTokenPricing.forModel('openai/gpt-4o-mini-2024');
      expect(p, isNotNull);
      final cost = p!.estimateUsd(inputTokens: 1000000, outputTokens: 1000000);
      expect(cost, closeTo(0.15 + 0.60, 0.0001));
    });

    test('unknown model returns null', () {
      expect(ModelTokenPricing.forModel('totally-unknown-xyz'), isNull);
    });
  });
}
