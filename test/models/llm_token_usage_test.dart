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
