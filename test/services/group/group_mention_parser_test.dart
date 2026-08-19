import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_dispatch_parser.dart';

RemoteAgent agent(String id, String name) => RemoteAgent(
      id: id,
      name: name,
      avatar: '🤖',
      token: '',
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  final agents = [
    agent('a1', '张三'),
    agent('a2', 'Tom Smith'),
    agent('a3', 'Reviewer'),
  ];

  group('resolveMentionDeclarations', () {
    test('null / empty / empty agents returns empty result', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(null, agents);
      expect(r.mentions, isEmpty);
      expect(r.unresolved, isEmpty);
      expect(
          GroupDispatchParser.resolveMentionDeclarations(const [], agents)
              .mentions,
          isEmpty);
      expect(
          GroupDispatchParser.resolveMentionDeclarations(const [{}], const [])
              .mentions,
          isEmpty);
    });

    test('metadata-shape entry resolves with notify defaulting to true', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'name': '张三'},
        ],
        agents,
      );
      expect(r.mentions.map((m) => m.id), ['a1']);
      expect(r.mentions.single.notify, isTrue);
      expect(r.unresolved, isEmpty);
    });

    test('notify: false is honored', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'name': 'Reviewer', 'notify': false},
        ],
        agents,
      );
      expect(r.mentions.single.notify, isFalse);
    });

    test('reason is carried; empty reason becomes null', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'name': '张三', 'reason': '  帮我 review 一下  '},
        ],
        agents,
      );
      expect(r.mentions.single.reason, '帮我 review 一下');
      final r2 = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'name': '张三', 'reason': '   '},
        ],
        agents,
      );
      expect(r2.mentions.single.reason, isNull);
    });

    test('"all" / "ALL" expands to every member with reason carried', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'name': 'all', 'reason': '全员确认'},
        ],
        agents,
      );
      expect(r.mentions.map((m) => m.id), ['a1', 'a2', 'a3']);
      expect(r.mentions.every((m) => m.reason == '全员确认'), isTrue);
      final r2 = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'name': 'ALL'},
        ],
        agents,
      );
      expect(r2.mentions.length, 3);
    });

    test('tool-args shape {"mentions": [...]} resolves identically', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          {
            'mentions': [
              {'name': '张三', 'notify': true},
              {'name': 'Reviewer', 'notify': false},
            ],
          },
        ],
        agents,
      );
      expect(r.mentions.map((m) => m.id), ['a1', 'a3']);
      expect(r.mentions.last.notify, isFalse);
    });

    test('mixed sources dedupe by id, first occurrence wins', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'mentions': [
            {'name': '张三', 'notify': true, 'reason': '第一'},
          ]},
          {'name': '张三', 'notify': false, 'reason': '第二'},
        ],
        agents,
      );
      expect(r.mentions.length, 1);
      expect(r.mentions.single.notify, isTrue);
      expect(r.mentions.single.reason, '第一');
    });

    test('unresolved names reported and deduped; resolved still emitted', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'name': '不存在'},
          {'name': '不存在'},
          {'name': '张三'},
        ],
        agents,
      );
      expect(r.mentions.map((m) => m.id), ['a1']);
      expect(r.unresolved, ['不存在']);
    });

    test('non-map items and empty names are skipped', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          'garbage',
          42,
          {'name': '  '},
          {'name': '张三'},
        ],
        agents,
      );
      expect(r.mentions.map((m) => m.id), ['a1']);
      expect(r.unresolved, isEmpty);
    });

    test('decorated names and agent ids resolve', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'name': '「张三」'},
          {'name': 'a3'},
        ],
        agents,
      );
      expect(r.mentions.map((m) => m.id), ['a1', 'a3']);
    });

    test('all plus specific entry yields no duplicates', () {
      final r = GroupDispatchParser.resolveMentionDeclarations(
        [
          {'name': 'all'},
          {'name': '张三'},
        ],
        agents,
      );
      expect(r.mentions.length, 3);
    });
  });

  group('findAgentByDispatchName', () {
    test('exact, case-insensitive, id and unique substring tiers', () {
      expect(GroupDispatchParser.findAgentByDispatchName(agents, '张三')?.id, 'a1');
      expect(GroupDispatchParser.findAgentByDispatchName(agents, 'tom smith')?.id, 'a2');
      expect(GroupDispatchParser.findAgentByDispatchName(agents, 'a3')?.id, 'a3');
      expect(GroupDispatchParser.findAgentByDispatchName(agents, 'Tom S')?.id, 'a2');
      expect(GroupDispatchParser.findAgentByDispatchName(agents, 'Nobody'), isNull);
      expect(GroupDispatchParser.findAgentByDispatchName(agents, ''), isNull);
    });
  });

  group('stripDispatchJsonBlocks', () {
    test('removes json fences and trims', () {
      const text = '好的\n```json\n{"dispatch":{}}\n```\n完毕';
      expect(GroupDispatchParser.stripDispatchJsonBlocks(text), '好的\n完毕');
    });

    test('case-insensitive fence', () {
      const text = '```JSON\n{"done":true}\n```';
      expect(GroupDispatchParser.stripDispatchJsonBlocks(text), '');
    });

    test('no block → unchanged', () {
      const text = '普通文本';
      expect(GroupDispatchParser.stripDispatchJsonBlocks(text), '普通文本');
    });
  });
}
