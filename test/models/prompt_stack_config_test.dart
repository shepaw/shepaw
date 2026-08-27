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

    test('stays lean: uri_only memory, no extra cognition or session-end', () {
      final cfg = PromptStackConfig.forOtherAgent;
      expect(cfg.agent.includeUserProfile, isTrue);
      expect(cfg.agent.includeAgentMemory, isTrue);
      expect(cfg.agent.includeAgentSelfCognition, isFalse);
      expect(cfg.agent.includeAgentUserCognition, isFalse);
      expect(cfg.agent.includeSessionEnd, isFalse);
      expect(cfg.memoryInjectMode, CognitionInjectMode.uriOnly);
      expect(cfg.embedMemoryEntries, isFalse);
      expect(cfg.soulInjectMode, CognitionInjectMode.full);
      expect(cfg.tools.toolDescriptionLevel, 'names_only');
    });
  });

  group('PromptStackConfig.forShe', () {
    test('keeps shepaw CLI and enables spirit-pet profile/strategy', () {
      expect(PromptStackConfig.forShe.tools.includeShepawCli, isTrue);
      expect(PromptStackConfig.forShe.she.includeSheMemory, isTrue);
      expect(PromptStackConfig.forShe.she.includeMetaCognition, isTrue);
      expect(PromptStackConfig.forShe.she.includeUserStrategy, isTrue);
      expect(PromptStackConfig.forShe.she.includeProfileSnapshot, isTrue);
      expect(PromptStackConfig.forShe.she.includeDmPlaybooks, isFalse);
      expect(PromptStackConfig.forShe.she.includeAgentsRoster, isTrue);
      expect(PromptStackConfig.forShe.she.includeExternalDigests, isTrue);
      expect(PromptStackConfig.forShe.agent.includeUserProfile, isFalse);
    });
  });
}
