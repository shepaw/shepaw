import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/hub_group_sessions.dart';

void main() {
  test('list/create/rename/archive frames carry the v2 fields', () {
    expect(
      HubGroupSessions.listFrame('group_g1', requestId: 'r1'),
      {
        'type': 'group_session_list_req',
        'request_id': 'r1',
        'group_id': 'group_g1',
      },
    );
    expect(
      HubGroupSessions.createFrame('group_g1', title: '第二轮', requestId: 'r2'),
      {
        'type': 'group_session_create_req',
        'request_id': 'r2',
        'group_id': 'group_g1',
        'title': '第二轮',
      },
    );
    expect(
      HubGroupSessions.renameFrame('group_g1', 's_1', '改名', requestId: 'r3'),
      {
        'type': 'group_session_rename_req',
        'request_id': 'r3',
        'group_id': 'group_g1',
        'session_id': 's_1',
        'title': '改名',
      },
    );
    expect(
      HubGroupSessions.archiveFrame('group_g1', 's_1', requestId: 'r4'),
      {
        'type': 'group_session_archive_req',
        'request_id': 'r4',
        'group_id': 'group_g1',
        'session_id': 's_1',
      },
    );
  });

  test('a v2 list response decodes id/title/status/created_at/last_task_at',
      () {
    final listed = GroupSessionListResult.fromResponse({
      'ok': true,
      'current_session': 's_2',
      'sessions': [
        {
          'id': 's_1',
          'title': '第一轮',
          'status': 'active',
          'created_at': 100,
          'last_task_at': 180,
        },
        {
          'id': 's_2',
          'title': '第二轮',
          'status': 'archived',
          'created_at': 200,
        },
      ],
    });
    expect(listed, isNotNull);
    expect(listed!.currentSession, 's_2');
    expect(listed.sessions.map((s) => s.id), ['s_1', 's_2']);
    expect(listed.sessions.first.title, '第一轮');
    expect(listed.sessions.first.lastTaskAt, 180);
    expect(listed.sessions.last.isArchived, isTrue);
    expect(listed.sessions.last.lastTaskAt, isNull);
  });

  test('a failed response is not a list', () {
    expect(
      GroupSessionListResult.fromResponse(
          {'ok': false, 'error': 'bad_session_id'}),
      isNull,
    );
  });

  test('the selection only remembers what was chosen', () {
    GroupSessionSelection.clear();
    expect(GroupSessionSelection.of('group_g1'), isNull);
    GroupSessionSelection.select('group_g1', 's_1');
    expect(GroupSessionSelection.of('group_g1'), 's_1');
    GroupSessionSelection.select('group_g1', '');
    expect(GroupSessionSelection.of('group_g1'), isNull);
  });
}
