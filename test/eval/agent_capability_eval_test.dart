import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/os/os_sandbox_config.dart';
import 'package:shepaw/clis/shepaw/os/os_sandbox_policy.dart';
import 'package:shepaw/controllers/dm_send_turn_planner.dart';
import 'package:shepaw/models/peer_boundary_config.dart';
import 'package:shepaw/models/prompt_stack_config.dart';
import 'package:shepaw/models/llm_token_usage.dart';
import 'package:shepaw/services/session/history_compaction_cache.dart';
import 'package:shepaw/services/session/history_compactor.dart';

import 'eval_helpers.dart';

/// Offline capability-contract suite for recent local-agent hardening.
///
/// Run: `flutter test test/eval`
///
/// Keeps scenarios free of path_provider / network / live LLM so they stay
/// in the default CI (`flutter test --exclude-tags=needs-plugins`).
void main() {
  tearDown(() {
    OsSandboxConfig.resetActive();
  });

  group('eval: OS sandbox policy', () {
    late OsSandboxPolicy policy;

    setUp(() {
      policy = OsSandboxPolicy(
        config: OsSandboxConfig.defaults,
        homeOverride: '/Users/eval',
      );
    });

    test('denies mutating system paths', () {
      expect(
        policy.evaluate('file_write', {'path': '/usr/bin/x'}).allowed,
        isFalse,
      );
      expect(
        policy.evaluate('file_delete', {'path': '/etc/passwd'}).allowed,
        isFalse,
      );
    });

    test('allows HOME delete and ordinary rm; denies catastrophic shell', () {
      expect(
        policy
            .evaluate('file_delete', {'path': '/Users/eval/Downloads/a.zip'})
            .allowed,
        isTrue,
      );
      expect(
        policy.evaluateShell('rm /Users/eval/Downloads/a.zip').allowed,
        isTrue,
      );
      expect(policy.evaluateShell('sudo ls').allowed, isFalse);
      expect(policy.evaluateShell('rm -rf /').allowed, isFalse);
    });
  });

  group('eval: peer inbound boundary', () {
    test('defaults block os and memory writes', () {
      const c = PeerBoundaryConfig.defaults;
      expect(c.blocksCli(namespace: 'os', subcommand: 'command.exec'), isTrue);
      expect(
        c.blocksCli(namespace: 'context', subcommand: 'memory.write'),
        isTrue,
      );
      expect(
        c.blocksCli(namespace: 'context', subcommand: 'agents.cognition-write'),
        isTrue,
      );
      expect(
        c.blocksCli(namespace: 'tools', subcommand: 'web.search'),
        isFalse,
      );
    });

    test('open boundary allows os and memory writes', () {
      const c = PeerBoundaryConfig.open;
      expect(c.blocksCli(namespace: 'os', subcommand: 'file.read'), isFalse);
      expect(
        c.blocksCli(namespace: 'context', subcommand: 'memory.write'),
        isFalse,
      );
    });

    test('She inbound strips host private context by default', () {
      final agent = evalAgent(metadata: {
        'is_she': true,
        'llm_provider': 'openai',
      });
      final inbound = agent.promptStackConfigForPeerInbound();
      expect(inbound.she.includeProfileSnapshot, isFalse);
      expect(inbound.she.includeUserCognition, isFalse);
      expect(inbound.she.includeUserStrategy, isFalse);
      expect(inbound.she.includeFirstMeeting, isFalse);
      expect(inbound.she.includeSessionEnd, isFalse);
      expect(inbound.she.includeSheMemory, isTrue);
    });

    test('open peer_boundary keeps host context flags', () {
      final agent = evalAgent(metadata: {
        'is_she': true,
        'llm_provider': 'openai',
        'peer_boundary': PeerBoundaryConfig.open.toJson(),
      });
      final inbound = agent.promptStackConfigForPeerInbound();
      expect(inbound.she.includeProfileSnapshot, isTrue);
      expect(inbound.she.includeSessionEnd, isTrue);
    });
  });

  group('eval: prompt stack defaults', () {
    test('forShe enables companion profile/strategy; forOther keeps shepaw tool',
        () {
      expect(PromptStackConfig.forShe.she.includeUserStrategy, isTrue);
      expect(PromptStackConfig.forShe.she.includeProfileSnapshot, isTrue);
      expect(PromptStackConfig.forShe.agent.includeUserProfile, isFalse);
      expect(PromptStackConfig.forOtherAgent.tools.includeShepawCli, isTrue);
      expect(PromptStackConfig.forOtherAgent.she.includeSheMemory, isFalse);
    });
  });

  group('eval: history compaction', () {
    test('under budget needs no compaction', () {
      final messages = [
        evalMsg(id: '1', content: 'hi'),
        evalMsg(id: '2', content: 'hello', isAgent: true),
      ];
      final plan = HistoryCompactor.plan(messages: messages, maxChars: 10000);
      expect(plan.needsCompaction, isFalse);
      expect(plan.older, isEmpty);
      expect(plan.recent, hasLength(2));
    });

    test('over budget splits with stable recent suffix', () {
      final messages = List.generate(
        20,
        (i) => evalMsg(
          id: '$i',
          content: 'm' * 200,
          isAgent: i.isEven,
        ),
      );
      final plan = HistoryCompactor.plan(
        messages: messages,
        maxChars: 500,
        keepRecentCount: 4,
        keepRecentChars: 900,
      );
      expect(plan.needsCompaction, isTrue);
      expect(plan.older.length + plan.recent.length, messages.length);
      expect(
        plan.recent.map((m) => m.id).toList(),
        messages
            .sublist(messages.length - plan.recent.length)
            .map((m) => m.id)
            .toList(),
      );
    });

    test('cache exact hit and prefix extension', () {
      final older = [
        evalMsg(id: 'a', content: '1'),
        evalMsg(id: 'b', content: '2'),
      ];
      final entry = HistoryCompactionCacheEntry.fromOlder(
        channelId: 'ch',
        summary: 'sum',
        older: older,
      );
      expect(entry.matchesExact(older), isTrue);
      expect(
        entry.isPrefixOf([
          ...older,
          evalMsg(id: 'c', content: '3'),
        ]),
        isTrue,
      );
      final transcript = HistoryCompactionCacheLogic.incrementalTranscript(
        previousSummary: 'prior',
        delta: [evalMsg(id: 'c', content: 'new')],
      );
      expect(transcript, contains('Previous conversation summary'));
      expect(transcript, contains('new'));
    });
  });

  group('eval: history supplement planner', () {
    test('maps null / pending / ready outcomes', () {
      expect(
        DmSendTurnPlanner.evaluateSupplementRound(
          supplementIsNull: true,
          actualSentCount: 0,
          messageContent: '',
        ).action,
        HistorySupplementRoundAction.noMoreHistory,
      );
      expect(
        DmSendTurnPlanner.evaluateSupplementRound(
          supplementIsNull: false,
          actualSentCount: 10,
          messageContent: '',
          pendingHistoryRequest: {'reason': 'more', 'request_id': 'r2'},
        ).action,
        HistorySupplementRoundAction.needMoreHistory,
      );
      expect(
        DmSendTurnPlanner.evaluateSupplementRound(
          supplementIsNull: false,
          actualSentCount: 5,
          messageContent: 'ok',
        ).action,
        HistorySupplementRoundAction.reanswerReady,
      );
    });
  });

  group('eval: token usage parsing', () {
    test('merges OpenAI then Claude-shaped usage', () {
      final a = LlmTokenUsage.fromJson({
        'prompt_tokens': 10,
        'completion_tokens': 2,
      })!;
      final b = a.merge(LlmTokenUsage.fromJson({
        'input_tokens': 10,
        'output_tokens': 8,
      }));
      expect(b.inputTokens, 10);
      expect(b.outputTokens, 8);
    });
  });
}
