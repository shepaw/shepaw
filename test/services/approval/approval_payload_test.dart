import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/approval/approval_reachability_notifier.dart';

void main() {
  test('approval payload prefix is stable for deep links', () {
    expect(ApprovalReachabilityNotifier.payloadPrefix, 'approval:');
    const channelId = 'ch-1';
    const messageId = 'msg-2';
    final payload =
        '${ApprovalReachabilityNotifier.payloadPrefix}$channelId:$messageId';
    final rest =
        payload.substring(ApprovalReachabilityNotifier.payloadPrefix.length);
    final colon = rest.indexOf(':');
    expect(rest.substring(0, colon), channelId);
    expect(rest.substring(colon + 1), messageId);
  });
}
