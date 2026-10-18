import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/local_database_service.dart';

void main() {
  test('批量期间的活动通知合并成一次', () async {
    final db = LocalDatabaseService();
    final events = <String>[];
    final sub = db.channelActivityStream.listen(events.add);
    addTearDown(sub.cancel);

    db.beginActivityBatch();
    db.notifyChannelActivity('a');
    db.notifyChannelActivity('b');
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty, reason: '批次未结束前不应发通知');

    db.endActivityBatch();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['']);

    // 嵌套批次要等最外层结束才发一次。
    db.beginActivityBatch();
    db.beginActivityBatch();
    db.notifyChannelActivity('c');
    db.endActivityBatch();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['']);

    db.endActivityBatch();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['', '']);

    // 批次之外保持原来的逐条通知。
    db.notifyChannelActivity('d');
    await Future<void>.delayed(Duration.zero);
    expect(events, ['', '', 'd']);
  });
}
