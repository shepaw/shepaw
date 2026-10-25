import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/hub_group_sessions.dart';
import 'package:shepaw/storage/pouch_attachment_scope.dart';
import 'package:shepaw/storage/pouch_scope.dart';

void main() {
  setUp(GroupSessionSelection.clear);
  tearDown(GroupSessionSelection.clear);

  test('群附件跟着这一端选过的会话走', () {
    expect(PouchAttachmentScopes.groupSession('g1'), isNull);
    expect(
      PouchAttachmentScopes.groupAttachmentUri(
        groupId: 'g1',
        pouchId: 'p1',
        file: 'a.png',
      ),
      isNull,
    );

    GroupSessionSelection.select('g1', 's1');
    expect(
      PouchAttachmentScopes.groupSession('g1')?.id,
      'group:g1:session:s1',
    );
    expect(
      PouchAttachmentScopes.groupAttachmentUri(
        groupId: 'g1',
        pouchId: 'p1',
        file: 'a.png',
      ),
      'pouch://p1/group:g1:session:s1/attachments/a.png',
    );

    // 切换会话后同一个调用点就换成新会话的 scope。
    GroupSessionSelection.select('g1', 's2');
    expect(
      PouchAttachmentScopes.groupAttachmentUri(
        groupId: 'g1',
        pouchId: 'p1',
        file: 'a.png',
        messageId: 'm1',
      ),
      'pouch://p1/group:g1:session:s2/attachments/m1/a.png',
    );
  });

  test('一条消息的附件落点：群认会话，单聊认 agent', () {
    expect(
      PouchAttachmentScopes.messageAttachmentTarget(
        agentId: 'a1',
        channelId: 'g1',
        messageId: 'm1',
        channelType: 'group',
      ),
      isNull,
      reason: '群还没选过会话时不猜主机的 current_session',
    );

    GroupSessionSelection.select('g1', 's1');
    final group = PouchAttachmentScopes.messageAttachmentTarget(
      agentId: 'a1',
      channelId: 'ch1',
      messageId: 'm1',
      channelType: 'group',
      parentGroupId: 'g1',
    );
    expect(group?.scope.id, 'group:g1:session:s1');
    expect(group?.directory, 'attachments/m1');

    final dm = PouchAttachmentScopes.messageAttachmentTarget(
      agentId: 'a1',
      channelId: 'dm1',
      messageId: 'm2',
    );
    expect(dm?.scope.id, 'agent:a1');
    expect(dm?.directory, 'files/attachments');
  });

  test('落点算不出来时返回 null，不抛', () {
    expect(
      PouchAttachmentScopes.messageAttachmentTarget(
        agentId: '',
        channelId: 'dm1',
        messageId: 'm2',
      ),
      isNull,
    );
    expect(
      PouchAttachmentScopes.messageAttachmentTarget(
        agentId: 'a@b',
        channelId: 'dm1',
        messageId: 'm2',
      ),
      isNull,
    );
    GroupSessionSelection.select('g1', 's1');
    expect(
      PouchAttachmentScopes.messageAttachmentTarget(
        agentId: 'a1',
        channelId: 'g1',
        messageId: '',
        channelType: 'group',
      ),
      isNull,
    );
  });

  test('别的群选会话不影响这个群', () {
    GroupSessionSelection.select('g2', 's9');
    expect(PouchAttachmentScopes.groupSession('g1'), isNull);
    expect(
      PouchAttachmentScopes.groupSession('g2')?.id,
      'group:g2:session:s9',
    );
  });

  test('agent 附件：有会话落会话，没有落 files/attachments', () {
    expect(
      PouchAttachmentScopes.agentAttachmentUri(
        agentId: 'a1',
        pouchId: 'p1',
        file: 'memo.md',
      ),
      'pouch://p1/agent:a1/files/attachments/memo.md',
    );
    expect(
      PouchAttachmentScopes.agentAttachmentUri(
        agentId: 'a1',
        pouchId: 'p1',
        file: 'memo.md',
        sessionId: 's1',
      ),
      'pouch://p1/agent:a1:session:s1/attachments/memo.md',
    );
    expect(PouchAttachmentScopes.agentSession('a1', ''), isNull);
  });

  test('附件地址里的空格和中文按 v3 编码', () {
    GroupSessionSelection.select('g1', 's1');
    final uri = PouchAttachmentScopes.groupAttachmentUri(
      groupId: 'g1',
      pouchId: 'p1',
      file: '聊天 记录.txt',
    );
    expect(
      uri,
      'pouch://p1/group:g1:session:s1/'
      'attachments/%E8%81%8A%E5%A4%A9%20%E8%AE%B0%E5%BD%95.txt',
    );
  });

  test('scope 本身不合法时构造抛错，不会拼出坏地址', () {
    expect(() => PouchScope.groupSession('g 1', 's1'), throwsFormatException);
  });
}
