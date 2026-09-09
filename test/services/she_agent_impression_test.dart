import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/dispatch_task.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/models/she_agent_impression.dart';
import 'package:shepaw/services/she_agent_impression_service.dart';

RemoteAgent _agent({
  String id = 'agent-1',
  String name = 'Coder',
  String? bio,
  List<String> capabilities = const [],
  Map<String, dynamic> metadata = const {},
}) {
  return RemoteAgent(
    id: id,
    name: name,
    avatar: '🤖',
    bio: bio,
    token: 'tok',
    endpoint: 'http://localhost',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.http,
    status: AgentStatus.online,
    capabilities: capabilities,
    metadata: metadata,
    createdAt: 0,
    updatedAt: 0,
  );
}

void main() {
  group('SheAgentImpression index codec', () {
    test('round-trips through JSON with she observations', () {
      final impression = SheAgentImpression(
        agentId: 'a1',
        agentName: 'Coder',
        oneLineRole: 'Dart backend specialist',
        experienceHint: 'Good at refactors',
        lastVerifiedAt: 1000,
        dispatchStats: const {'done': 2},
        sheObservations: const ['Good at refactors', 'Dispatch succeeded (2026-09-09)'],
      );
      final encoded = SheAgentImpression.encodeIndex({'a1': impression});
      final decoded = SheAgentImpression.decodeIndex(encoded);
      expect(decoded['a1']?.agentName, 'Coder');
      expect(decoded['a1']?.sheObservations.length, 2);
      expect(decoded['a1']?.dispatchStats['done'], 2);
    });
  });

  group('SheAgentImpressionAnnouncement codec', () {
    test('round-trips announcement list', () {
      final items = [
        SheAgentImpressionAnnouncement(
          agentId: 'a1',
          agentName: 'Coder',
          oneLineRole: 'Backend',
          kind: 'new',
          createdAt: 1,
        ),
        SheAgentImpressionAnnouncement(
          agentId: 'a2',
          agentName: 'Research',
          oneLineRole: 'Search',
          kind: 'updated',
          previousOneLineRole: 'General',
          createdAt: 2,
        ),
      ];
      final raw = SheAgentImpressionAnnouncement.encodeList(items);
      final decoded = SheAgentImpressionAnnouncement.decodeList(raw);
      expect(decoded.length, 2);
      expect(decoded.first.isNew, isTrue);
      expect(decoded.last.previousOneLineRole, 'General');
    });
  });

  group('SheAgentImpressionService.buildOneLineRole', () {
    test('prefers soul first line over bio', () {
      final role = SheAgentImpressionService.buildOneLineRole(
        _agent(bio: 'bio line'),
        '## Coding helper\nLonger soul body',
      );
      expect(role, startsWith('Coding helper'));
    });

    test('skips markdown section headings in soul', () {
      final role = SheAgentImpressionService.buildOneLineRole(
        _agent(),
        '## Specialty\n擅长 Dart/Flutter 重构',
      );
      expect(role, contains('Dart'));
    });

    test('falls back to bio then capabilities', () {
      expect(
        SheAgentImpressionService.buildOneLineRole(_agent(bio: 'Research'), ''),
        'Research',
      );
      expect(
        SheAgentImpressionService.buildOneLineRole(
          _agent(capabilities: ['search', 'summarize']),
          '',
        ),
        'search, summarize',
      );
    });

    test('appends enabled skills when within budget', () {
      final role = SheAgentImpressionService.buildOneLineRole(
        _agent(
          bio: 'Helper',
          metadata: {
            'enabled_skills': ['git', 'shell'],
          },
        ),
        '',
      );
      expect(role, 'Helper; skills: git, shell');
    });
  });

  group('SheAgentImpressionService.buildExperienceHint', () {
    test('prefers she observations over learnings and stats', () {
      expect(
        SheAgentImpressionService.buildExperienceHint(
          stats: const {'done': 9},
          learnings: const ['From agent memory'],
          sheObservations: const ['She-owned note'],
        ),
        'She-owned note',
      );
    });

    test('falls back to dispatch learnings over stats', () {
      expect(
        SheAgentImpressionService.buildExperienceHint(
          stats: const {'done': 9},
          learnings: const ['Good at Dart refactors (2026-07)'],
        ),
        'Good at Dart refactors (2026-07)',
      );
    });

    test('summarizes dispatch stats when no observations', () {
      expect(
        SheAgentImpressionService.buildExperienceHint(
          stats: const {'done': 2, 'error': 1, 'timeout': 0},
        ),
        'Dispatch record: 2 ok, 1 fail, 0 timeout',
      );
    });

    test('marks agents without dispatch history', () {
      expect(
        SheAgentImpressionService.buildExperienceHint(stats: const {}),
        'Not yet verified by dispatch',
      );
    });
  });

  group('SheAgentImpressionService.buildDispatchObservation', () {
    test('formats terminal dispatch statuses', () {
      expect(
        SheAgentImpressionService.buildDispatchObservation(
          DispatchTask.statusDone,
        ),
        contains('Dispatch succeeded'),
      );
      expect(
        SheAgentImpressionService.buildDispatchObservation(
          DispatchTask.statusTimeout,
        ),
        contains('timed out'),
      );
      expect(
        SheAgentImpressionService.buildDispatchObservation(
          DispatchTask.statusError,
          errorMessage: 'connection reset',
        ),
        contains('connection reset'),
      );
    });
  });

  group('SheAgentImpressionService.formatAnnouncementsBlock', () {
    test('renders new and updated agents', () {
      final block = SheAgentImpressionService.formatAnnouncementsBlock([
        SheAgentImpressionAnnouncement(
          agentId: 'a1',
          agentName: 'Coder',
          oneLineRole: 'Backend specialist',
          kind: 'new',
          createdAt: 1,
        ),
        SheAgentImpressionAnnouncement(
          agentId: 'a2',
          agentName: 'Research',
          oneLineRole: 'Search expert',
          kind: 'updated',
          previousOneLineRole: 'General helper',
          createdAt: 2,
        ),
      ]);
      expect(block, contains('**NEW** Coder'));
      expect(block, contains('Backend specialist'));
      expect(block, contains('**UPDATED** Research'));
      expect(block, contains('was "General helper"'));
      expect(block, contains('mention once'));
    });
  });

  group('SheAgentImpressionService.formatDirectoryLines', () {
    test('renders name, status, role, and experience', () {
      final lines = SheAgentImpressionService.formatDirectoryLines(
        agents: [_agent(name: 'Coder')],
        impressions: {
          'agent-1': SheAgentImpression(
            agentId: 'agent-1',
            agentName: 'Coder',
            oneLineRole: 'Backend specialist',
            experienceHint: 'Dispatch record: 1 ok, 0 fail, 0 timeout',
            lastVerifiedAt: 1,
          ),
        },
      );
      expect(lines.single, contains('**Coder** (online)'));
      expect(lines.single, contains('Backend specialist'));
      expect(lines.single, contains('Dispatch record'));
    });
  });
}
