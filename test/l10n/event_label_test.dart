import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/l10n/l10n_helpers.dart';
import 'package:shepaw/services/event/event_delivery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations zh;
  late AppLocalizations en;

  setUpAll(() async {
    zh = await AppLocalizations.delegate.load(const Locale('zh'));
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('localizeEventTypeLabel', () {
    test('精确类型名命中', () {
      expect(localizeEventTypeLabel(zh, 'peer.pairing.inbound'), '设备配对请求');
      expect(localizeEventTypeLabel(zh, 'chat.group.step.failed'), '编排步骤失败');
      expect(localizeEventTypeLabel(zh, 'workflow.approval.pending'), '工作流待审批');
      expect(localizeEventTypeLabel(zh, 'test.event.pong'), '测试事件 Pong');
    });

    test('英文 locale 走同一张表', () {
      expect(
        localizeEventTypeLabel(en, 'peer.pairing.inbound'),
        'Device pairing request',
      );
      expect(
        localizeEventTypeLabel(en, 'store.backup.failed'),
        'Backup failed',
      );
    });

    test('通配 pattern 命中家族名', () {
      expect(localizeEventTypeLabel(zh, 'chat.group.*'), '群聊编排 · *');
      expect(localizeEventTypeLabel(zh, 'workflow.*'), '工作流 · *');
      expect(localizeEventTypeLabel(zh, 'store.*'), '存储 · *');
      // 单段家族键兜住更深一层的通配。
      expect(localizeEventTypeLabel(zh, 'peer.pairing.*'), '设备配对 · *');
    });

    test('未知类型原样返回', () {
      // `agent.<id>.*` 只在首次 emit 时注册，标签表必须兜底。
      expect(
        localizeEventTypeLabel(zh, 'agent.abc.custom.done'),
        'agent.abc.custom.done',
      );
      expect(localizeEventTypeLabel(zh, 'agent.*'), 'Agent 自定义 · *');
      // 非 `.*` 结尾的通配不猜家族。
      expect(
        localizeEventTypeLabel(zh, 'chat.group.*.failed'),
        'chat.group.*.failed',
      );
      expect(localizeEventTypeLabel(zh, 'nope.nope.*'), 'nope.nope.*');
      expect(localizeEventTypeLabel(zh, ''), '');
    });
  });

  group('EventDelivery 档位名称化', () {
    test('三档映射', () {
      expect(EventDelivery.pollOnly.localizedLabel(zh), '轮询');
      expect(EventDelivery.passive.localizedLabel(zh), '被动');
      expect(EventDelivery.active.localizedLabel(zh), '主动');
      expect(EventDelivery.pollOnly.localizedLabel(en), 'Poll only');
    });

    test('localizeEventDelivery 接受线上值并回退原文', () {
      expect(localizeEventDelivery(zh, 'poll_only'), '轮询');
      expect(localizeEventDelivery(zh, 'active'), '主动');
      expect(localizeEventDelivery(zh, 'legacy_mode'), 'legacy_mode');
      expect(localizeEventDelivery(zh, null), isNull);
      expect(localizeEventDelivery(zh, ''), isNull);
    });
  });
}
