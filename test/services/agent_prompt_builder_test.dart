import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
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

    test('buildMetaCognitionBlock prefers store for produced artifacts', () {
      final block = SheService.buildMetaCognitionBlock();
      expect(block, contains('shepaw store write'));
      expect(block, contains('Produced Artifacts'));
      expect(block, contains('prefer store'));
      expect(block, contains('Prefer store for produced artifacts'));
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
      expect(prompt, contains('shepaw store write'));
      expect(prompt, contains('prefer store'));
      expect(prompt, isNot(contains('shepaw CLI — Data Access')));
      expect(prompt, isNot(contains('buildDmWorkflowPlaybookBlock')));
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
