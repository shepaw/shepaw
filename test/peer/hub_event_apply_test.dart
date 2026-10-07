import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/hub_event_apply.dart';

HubEvent event(int seq, [String kind = 'message.created']) {
  return HubEvent(
    seq: seq,
    kind: kind,
    channelId: 'dm',
    agentId: 'she',
    origin: 'hub',
    data: const {'id': 'm'},
  );
}

void main() {
  test('序号连续就收下，重复丢掉，中间缺了要补', () {
    expect(cursorStep(0, 1), HubCursorStep.apply);
    expect(cursorStep(4, 5), HubCursorStep.apply);
    expect(cursorStep(5, 5), HubCursorStep.duplicate);
    expect(cursorStep(5, 8), HubCursorStep.gap);
  });

  test('重置后游标跳到这页最后一条', () {
    final page = HubSyncPage(
      events: [event(4), event(5)],
      headSeq: 5,
      reset: true,
    );
    expect(cursorAfterPage(9, page), 5);
    expect(syncCaughtUp(5, 5), isTrue);
    expect(syncCaughtUp(4, 5), isFalse);
  });

  test('正常一页只前进连续的序号', () {
    final page = HubSyncPage(
      events: [event(2), event(3)],
      headSeq: 3,
      reset: false,
    );
    expect(cursorAfterPage(1, page), 3);
  });

  test('同步响应和消息去重', () {
    final page = HubSyncPage.parse({
      'head_seq': 2,
      'reset': false,
      'events': [
        {
          'seq': 2,
          'kind': 'message.created',
          'channel_id': 'dm',
          'data': {'id': 'm2'},
        },
      ],
    });
    expect(page?.events.single.seq, 2);
    expect(page?.headSeq, 2);
    expect(shouldInsertMessage(false), isTrue);
    expect(shouldInsertMessage(true), isFalse);
    expect(liveTurnPlaceholderId('t1'), 'hub-live-t1');
  });
}
