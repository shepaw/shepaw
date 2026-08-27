import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/mention_entry.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_verbal_dispatch.dart';

RemoteAgent _agent(String id, String name) => RemoteAgent(
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
  final coder = _agent('coder', 'Coder');
  final writer = _agent('writer', 'Writer');
  final tom = _agent('tom', 'Tom');
  final tommy = _agent('tommy', 'Tommy');
  final members = [coder, writer];

  List<String> names(String content, {List<MentionEntry> mentions = const []}) =>
      GroupVerbalDispatchDetector.promisedNames(
        content: content,
        members: members,
        mentions: mentions,
      );

  test('prefix verbs capture a named member', () {
    expect(names('我让 Coder 去做登录'), ['Coder']);
    expect(names('请 Writer 出一版文案'), ['Writer']);
    expect(names('接下来安排 Coder 实现接口'), ['Coder']);
    expect(names('交给 Writer 来润色'), ['Writer']);
  });

  test('suffix verbs capture a named member', () {
    expect(names('Coder 去实现登录'), ['Coder']);
    expect(names('Writer 来写README'), ['Writer']);
    expect(names('Coder will handle the API'), ['Coder']);
  });

  test('@mention and @all count as verbal dispatch', () {
    expect(names('请 @Coder 帮忙看下这段'), ['Coder']);
    expect(names('＠Writer 来补测试'), ['Writer']);
    expect(names('请 @all 各自认领一块'), ['Coder', 'Writer']);
  });

  test('English ask/assign/have', () {
    expect(names('I will ask Coder to implement login'), ['Coder']);
    expect(names('Assign Writer the copy.'), ['Writer']);
  });

  test('reporting or thanks is not dispatch', () {
    expect(names('根据 Coder 的回复，任务已完成'), isEmpty);
    expect(names('Coder 已经写完了'), isEmpty);
    expect(names('谢谢 Writer'), isEmpty);
    expect(names('Writer 的方案可以用，我来收尾'), isEmpty);
  });

  test('negation is not dispatch', () {
    expect(names('不让 Coder 做了，我自己来'), isEmpty);
    expect(names('不要叫 Writer 改'), isEmpty);
    expect(names('没有让 Coder 去做登录'), isEmpty);
  });

  test('Tom is not matched inside Tommy', () {
    expect(
      GroupVerbalDispatchDetector.promisedNames(
        content: 'ask Tommy to review',
        members: [tom, tommy],
      ),
      ['Tommy'],
    );
  });

  test('structured notify mentions count; cc-only do not', () {
    expect(
      names('我来安排一下', mentions: [
        const MentionEntry(id: 'coder', name: 'Coder', notify: true),
      ]),
      ['Coder'],
    );
    expect(
      names('抄送 Writer', mentions: [
        const MentionEntry(id: 'writer', name: 'Writer', notify: false),
      ]),
      isEmpty,
    );
  });

  test('empty and skip produce no hits', () {
    expect(names(''), isEmpty);
    expect(names('无事可做 [SKIP]'), isEmpty);
  });

  test('nudge copy names the members', () {
    expect(
      GroupVerbalDispatchDetector.nudgeSystemContent(['Coder']),
      contains('Coder'),
    );
    expect(
      GroupVerbalDispatchDetector.nudgeSystemContent(['Coder']),
      contains('group_dispatch'),
    );
    expect(
      GroupVerbalDispatchDetector.exhaustedWarning(['Coder', 'Writer']),
      contains('Coder、Writer'),
    );
  });
}
