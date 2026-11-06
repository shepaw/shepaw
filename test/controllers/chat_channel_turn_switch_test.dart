import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/peer/services/session_runtime_mirror.dart';
import 'package:shepaw/service_locator.dart' show getIt;

import '../storage/test_harness.dart';

/// A6-2：切频道后按停止，不能把上一个频道的 flow turn id 发出去。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelA = 'psess_flow_aaaa1111_impl';
  const channelB = 'psess_flow_bbbb2222_impl';
  const keyA = 'agent:agent-7:flow_aaaa1111_impl';
  const turnA = 'flow-aaaa1111-impl-a1';

  late SessionRuntimeMirror mirror;
  late ChatController controller;

  setUp(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
    mirror = SessionRuntimeMirror();
    if (getIt.isRegistered<SessionRuntimeMirror>()) {
      await getIt.unregister<SessionRuntimeMirror>();
    }
    getIt.registerSingleton<SessionRuntimeMirror>(mirror);
    controller = ChatController(
      agentId: 'agent-7',
      initialChannelId: channelA,
      getUserId: () => 'user',
      getUserName: () => 'User',
    );
    controller.currentChannelId = channelA;
  });

  tearDown(() async {
    controller.dispose();
    if (getIt.isRegistered<SessionRuntimeMirror>()) {
      await getIt.unregister<SessionRuntimeMirror>();
    }
  });

  test('切频道清空 runtime turn id，停止只认当前频道 mirror', () async {
    mirror.apply({
      'session_key': keyA,
      'state': 'running',
      'turn_id': turnA,
      'peer_id': 'p1',
      'revision': 1,
      'hub_id': 'hub-1',
    }, force: true);
    expect(controller.debugRuntimeActiveTurnId, turnA);
    expect(controller.currentChannelRuntimeTurnId, turnA);

    await controller.switchChannel(channelB);

    expect(controller.currentChannelId, channelB);
    expect(controller.debugRuntimeActiveTurnId, isNull,
        reason: 'A 的 running turn id 不能留给 B 的停止按钮');
    expect(controller.currentChannelRuntimeTurnId, isNull,
        reason: 'B 没有自己的 mirror 状态时不应带出任何 turn id');
  });
}
