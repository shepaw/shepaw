import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/prompt_stack_config.dart';

void main() {
  group('PromptStackConfig.forOtherAgent', () {
    test('enables shepaw CLI tool by default', () {
      expect(PromptStackConfig.forOtherAgent.tools.includeShepawCli, isTrue);
      expect(PromptStackConfig.forOtherAgent.tools.includeShepawMetaCli, isTrue);
    });

    test('disables She-exclusive stack sections', () {
      final she = PromptStackConfig.forOtherAgent.she;
      expect(she.includeSheMemory, isFalse);
      expect(she.includeMetaCognition, isFalse);
      expect(she.includeSessionEnd, isFalse);
    });
  });

  group('PromptStackConfig.forShe', () {
    test('keeps shepaw CLI and enables companion profile/strategy', () {
      expect(PromptStackConfig.forShe.tools.includeShepawCli, isTrue);
      expect(PromptStackConfig.forShe.she.includeSheMemory, isTrue);
      expect(PromptStackConfig.forShe.she.includeMetaCognition, isTrue);
      expect(PromptStackConfig.forShe.she.includeUserStrategy, isTrue);
      expect(PromptStackConfig.forShe.she.includeProfileSnapshot, isTrue);
      expect(PromptStackConfig.forShe.agent.includeUserProfile, isFalse);
    });
  });
}
