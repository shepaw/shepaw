import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/prompt_stack_config.dart';

/// Persistence contract for the Prompt Stack settings UI:
/// edits are written to `metadata['prompt_stack_config']` via [toJson],
/// and reloaded via [PromptStackConfig.fromJson] / agent getter.
void main() {
  group('PromptStackConfig UI persistence round-trip', () {
    test('She edits survive metadata json', () {
      final edited = PromptStackConfig.forShe.copyWith(
        lightweightMode: true,
        tools: PromptStackConfig.forShe.tools.copyWith(
          includeShepawCli: false,
          toolDescriptionLevel: 'full',
        ),
        she: PromptStackConfig.forShe.she.copyWith(
          includeUserStrategy: false,
          includeProfileSnapshot: true,
          profileSnapshotLevel: 'core',
          includeDmPlaybooks: true,
        ),
      );

      final metadata = <String, dynamic>{
        'prompt_stack_config': edited.toJson(),
      };
      final restored = PromptStackConfig.fromJson(
        Map<String, dynamic>.from(metadata['prompt_stack_config'] as Map),
      );

      expect(restored.lightweightMode, isTrue);
      expect(restored.tools.includeShepawCli, isFalse);
      expect(restored.tools.toolDescriptionLevel, 'full');
      expect(restored.she.includeUserStrategy, isFalse);
      expect(restored.she.includeProfileSnapshot, isTrue);
      expect(restored.she.profileSnapshotLevel, 'core');
      expect(restored.she.includeDmPlaybooks, isTrue);
    });

    test('non-She agent edits survive metadata json', () {
      final edited = PromptStackConfig.forOtherAgent.copyWith(
        includeIdentity: false,
        tools: PromptStackConfig.forOtherAgent.tools.copyWith(
          includeOsTools: false,
          osToolsMode: 'expanded',
        ),
        agent: PromptStackConfig.forOtherAgent.agent.copyWith(
          includeAgentMemory: false,
          includeSessionEnd: true,
          memoryLimit: 3,
        ),
        soulInjectMode: CognitionInjectMode.uriOnly,
        memoryInjectMode: CognitionInjectMode.uriOnly,
      );

      final restored = PromptStackConfig.fromJson(edited.toJson());
      expect(restored.includeIdentity, isFalse);
      expect(restored.tools.includeOsTools, isFalse);
      expect(restored.tools.osToolsMode, 'expanded');
      expect(restored.agent.includeAgentMemory, isFalse);
      expect(restored.agent.includeSessionEnd, isTrue);
      expect(restored.agent.memoryLimit, 3);
      expect(restored.soulInjectMode, CognitionInjectMode.uriOnly);
      expect(restored.memoryInjectMode, CognitionInjectMode.uriOnly);
      // She section stays disabled preset for other agents.
      expect(restored.she.includeSheMemory, isFalse);
    });

    test('lightweight forces effective inject modes to uri_only', () {
      final cfg = PromptStackConfig.forOtherAgent.copyWith(
        lightweightMode: true,
        soulInjectMode: CognitionInjectMode.full,
        memoryInjectMode: CognitionInjectMode.full,
      );
      expect(cfg.effectiveSoulInjectMode, CognitionInjectMode.uriOnly);
      expect(cfg.effectiveMemoryInjectMode, CognitionInjectMode.uriOnly);
      expect(cfg.embedSoulText, isFalse);
      expect(cfg.embedMemoryEntries, isFalse);
    });

    test('uri_only without lightweight skips embed helpers', () {
      final cfg = PromptStackConfig.forOtherAgent.copyWith(
        soulInjectMode: CognitionInjectMode.uriOnly,
        memoryInjectMode: CognitionInjectMode.uriOnly,
      );
      expect(cfg.effectiveSoulInjectMode, CognitionInjectMode.uriOnly);
      expect(cfg.embedSoulText, isFalse);
      expect(cfg.embedMemoryEntries, isFalse);
    });

    test('reset targets match factory presets', () {
      expect(
        PromptStackConfig.fromJson(PromptStackConfig.forShe.toJson())
            .she
            .includeUserStrategy,
        isTrue,
      );
      expect(
        PromptStackConfig.fromJson(PromptStackConfig.forOtherAgent.toJson())
            .tools
            .includeShepawCli,
        isTrue,
      );
      expect(
        PromptStackConfig.fromJson(PromptStackConfig.forOtherAgent.toJson())
            .memoryInjectMode,
        CognitionInjectMode.uriOnly,
      );
    });
  });
}
