import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/models/prompt_stack_config.dart';
import 'package:shepaw/services/agent_prompt_builder.dart';
import 'package:shepaw/services/she_service.dart';

RemoteAgent _localAgent({
  required String id,
  required String name,
  Map<String, dynamic>? metadata,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RemoteAgent(
    id: id,
    name: name,
    token: 't',
    endpoint: '',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.http,
    createdAt: now,
    updatedAt: now,
    metadata: {
      'llm_provider': 'openai',
      // Avoid DB-backed agent memory/cognition blocks in unit tests.
      'prompt_stack_config': {
        'she': {
          'include_she_memory': false,
          'include_meta_cognition': false,
          'include_session_end': false,
          'include_first_meeting': false,
        },
        'agent': {
          'include_user_profile': false,
          'include_agent_memory': false,
          'include_agent_self_cognition': false,
          'include_agent_user_cognition': false,
        },
        'tools': {
          'include_shepaw_cli': true,
          'include_shepaw_meta_cli': true,
          'include_ui': false,
          'include_os_tools': false,
          'include_skills': false,
          'include_tool_models': false,
        },
      },
      ...?metadata,
    },
  );
}

void main() {
  group('SheService ephemeral helpers', () {
    test('wrapEphemeralContextPrompt marks room-only context', () {
      final block = SheService.wrapEphemeralContextPrompt('group rules here');
      expect(block, contains('Current Room Context'));
      expect(block, contains('group rules here'));
      expect(block, contains('Do NOT copy it into soul'));
      expect(block, isNot(contains("Master's Custom Settings")));
    });

    test('buildEphemeralSessionEndBlock warns against writing room roles into soul', () {
      final block = SheService.buildEphemeralSessionEndBlock();
      expect(block, contains('ephemeral room'));
      expect(block, contains('Do NOT'));
      expect(block, contains('soul'));
    });

    test('buildMetaCognitionBlock points store usage at the Scope Card', () {
      final block = SheService.buildMetaCognitionBlock();
      // Detailed store read/write commands live in the Scope Card (当前储物袋
      // 作用域), which is the single pouch manual; the system prompt only
      // points at it and pins the two hard rules.
      expect(block, contains('### Store'));
      expect(block, contains('当前储物袋作用域'));
      expect(block, contains('Scope Card'));
      expect(block, contains('Do not invent `store://` URIs'));
      expect(block, contains('store write'));
      expect(block, isNot(contains('[implicit]')));
      // Detailed MUST/Do-NOT store-read lecture moved off the system prompt.
      expect(block, isNot(contains('MUST** read/operate via store CLI')));
    });

    test('buildMetaCognitionBlock covers vision album remove/get and debug engine', () {
      final block = SheService.buildMetaCognitionBlock();
      expect(block, contains('shepaw vision recognize'));
      expect(block, contains('album.enroll'));
      expect(block, contains('album.remove'));
      expect(block, contains('profile.build'));
      expect(block, contains('profile.get'));
      expect(block, contains('engine.is_debug'));
      expect(block, contains('do **not** guess a name'));
    });

    test('buildMetaCognitionBlock stays compact and defers playbooks to CLI help', () {
      final block = SheService.buildMetaCognitionBlock();
      expect(block.length, lessThan(2800));
      expect(block, isNot(contains('use FIRST')));
      expect(block, contains('shepaw workflow --help'));
      expect(block, contains('shepaw chat group --help'));
      expect(block, isNot(contains('pending_approval')));
    });
  });

  group('AgentPromptBuilder non-She', () {
    test('includes meta shepaw guidance but not She data-access CLI block', () async {
      final agent = _localAgent(id: 'local-coder', name: 'Coder');
      // Re-enable meta guidance (template above disabled she meta for She;
      // for non-She guidance uses tools.includeShepawMetaCli which is true).
      final prompt = await AgentPromptBuilder(agent: agent).buildSystemPrompt();

      expect(prompt, contains('Your name is Coder.'));
      expect(prompt, contains('Tool Discovery'));
      // Store guidance is a pointer to the Scope Card, not a CLI lecture.
      expect(prompt, contains('### Store'));
      expect(prompt, contains('Scope Card'));
      expect(prompt, isNot(contains('[implicit]')));
      expect(prompt, isNot(contains('shepaw CLI — Data Access')));
      expect(prompt, isNot(contains('buildDmWorkflowPlaybookBlock')));
    });

    test('puts current time in the dynamic suffix so the static prefix can cache',
        () async {
      final agent = _localAgent(id: 'local-coder', name: 'Coder');
      final built = await AgentPromptBuilder(agent: agent).build();

      expect(built.dynamicSuffix, contains('## Current Time'));
      expect(built.staticPrefix, isNot(contains('## Current Time')));
      expect(built.staticPrefix, contains('Your name is Coder.'));
      expect(built.full.endsWith(built.dynamicSuffix.trim()), isTrue);
    });

    test('DM custom prompt is wrapped as Master custom settings', () async {
      final agent = _localAgent(id: 'local-coder', name: 'Coder');
      final prompt = await AgentPromptBuilder(
        agent: agent,
        dmSystemPromptOverride: 'Be terse',
      ).buildSystemPrompt();

      expect(prompt, contains("Master's Custom Settings"));
      expect(prompt, contains('Be terse'));
    });

    test('resume block skips store read/write lecture', () async {
      final agent = _localAgent(id: 'local-coder', name: 'Coder');
      final prompt = await AgentPromptBuilder(agent: agent).buildSystemPrompt();

      expect(prompt, contains('## Your Resume'));
      expect(prompt, contains('agents.resume-set'));
      expect(prompt, isNot(contains('store write --space files')));
      expect(prompt, isNot(contains('Before This Conversation Ends')));
    });

    test('opt-in session-end writes for non-She', () async {
      final agent = _localAgent(
        id: 'local-coder',
        name: 'Coder',
        metadata: {
          'prompt_stack_config': PromptStackConfig.forOtherAgent
              .copyWith(
                tools: PromptStackConfig.forOtherAgent.tools.copyWith(
                  includeUI: false,
                  includeOsTools: false,
                  includeSkills: false,
                  includeToolModels: false,
                ),
                agent: PromptStackConfig.forOtherAgent.agent.copyWith(
                  includeUserProfile: false,
                  includeSessionEnd: true,
                ),
              )
              .toJson(),
        },
      );
      final prompt = await AgentPromptBuilder(agent: agent).buildSystemPrompt();
      expect(prompt, contains('Before This Conversation Ends'));
      expect(prompt, contains('agents.memory-write'));
    });
  });

  group('AgentPromptBuilder.clipSoulForPrompt', () {
    test('keeps short souls and tails long ones', () {
      expect(AgentPromptBuilder.clipSoulForPrompt('hello'), 'hello');
      final long = 'x' * 5000;
      final clipped = AgentPromptBuilder.clipSoulForPrompt(long);
      expect(clipped.length, lessThan(long.length));
      expect(clipped, contains('[older entries omitted]'));
      expect(clipped.endsWith('x' * AgentPromptBuilder.soulPromptMaxChars), isTrue);
    });
  });

  group('AgentPromptBuilder.sheRoomContext', () {
    test('keeps layered split so online/loop stay out of the static dump', () {
      const layered = BuiltSystemPrompt(
        staticPrefix: '【群聊名称】Team\n你是管理员',
        dynamicSuffix: '【成员在线】\nCoder：在线\n\n【当前状态】这是第 2 轮',
      );
      final room = AgentPromptBuilder.sheRoomContext(
        layered: layered,
        fallback: layered.full,
      );
      expect(room.staticCtx, '【群聊名称】Team\n你是管理员');
      expect(room.dynamicCtx, contains('【成员在线】'));
      expect(room.dynamicCtx, contains('第 2 轮'));
      expect(room.staticCtx, isNot(contains('【成员在线】')));
    });

    test('legacy full blob falls back into the static prefix', () {
      final room = AgentPromptBuilder.sheRoomContext(
        fallback: '【群聊名称】Team\n【成员在线】\nCoder：在线',
      );
      expect(room.staticCtx, contains('【成员在线】'));
      expect(room.dynamicCtx, isNull);
    });
  });

  group('AgentPromptBuilder ephemeral dynamic suffix', () {
    test('room rules stay static; online/loop stay in the suffix before time',
        () async {
      final agent = _localAgent(id: 'local-coder', name: 'Coder');
      final built = await AgentPromptBuilder(
        agent: agent,
        ephemeralContext: '【群聊名称】Team\n你是本群的管理员。',
        ephemeralDynamicSuffix: '【成员在线】\nCoder：在线',
      ).build();

      expect(built.staticPrefix, contains('Current Room Context'));
      expect(built.staticPrefix, contains('【群聊名称】Team'));
      expect(built.staticPrefix, isNot(contains('【成员在线】')));
      expect(built.dynamicSuffix, contains('【成员在线】'));
      expect(built.dynamicSuffix, contains('## Current Time'));
      expect(
        built.dynamicSuffix.indexOf('【成员在线】'),
        lessThan(built.dynamicSuffix.indexOf('## Current Time')),
      );
    });
  });

  group('AgentPromptBuilder She ephemeralContext', () {
    // Prefetch touches minds/she_memory DBs (path_provider).
    test(
      'injects ephemeral room context and skips DM workflow playbook',
      () async {
        final agent = _localAgent(
          id: SheService.sheId,
          name: SheService.sheName,
          metadata: {
            'is_she': true,
            'prompt_stack_config': {
              'she': {
                'include_she_memory': false,
                'include_she_self_cognition': false,
                'include_user_cognition': false,
                'include_user_strategy': false,
                'include_profile_snapshot': false,
                'include_first_meeting': false,
                'include_session_end': true,
                'include_meta_cognition': true,
                'enable_profile_command': false,
                'enable_memory_command': false,
                'enable_agent_chat_command': false,
                'enable_messages_command': false,
              },
              'agent': {
                'include_user_profile': false,
                'include_agent_memory': false,
                'include_agent_self_cognition': false,
                'include_agent_user_cognition': false,
              },
              'tools': {
                'include_shepaw_cli': true,
                'include_shepaw_meta_cli': false,
                'include_ui': false,
                'include_os_tools': false,
                'include_skills': false,
                'include_tool_models': false,
              },
            },
          },
        );

        final prompt = await AgentPromptBuilder(
          agent: agent,
          ephemeralContext: 'You are the group admin. Members: A, B.',
        ).buildSystemPrompt();

        expect(prompt, contains('Current Room Context'));
        expect(prompt, contains('You are the group admin. Members: A, B.'));
        expect(prompt, contains('ephemeral room'));
        // DM workflow playbook must not appear in ephemeral/group context.
        expect(prompt, isNot(contains('pending_approval')));
        expect(prompt, isNot(contains("Master's Custom Settings")));
      },
      tags: ['needs-plugins'],
    );
  });
}
