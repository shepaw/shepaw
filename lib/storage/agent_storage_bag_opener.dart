import 'package:flutter/material.dart';

import '../screens/agent_storage_bag_screen.dart';

/// 打开某个 agent 的储物袋。
///
/// 聊天抽屉和 agent 详情共用这一个入口，两边看到的内容才一致。
Future<void> openAgentStorageBag(
  BuildContext context, {
  required String ownerId,
  required String displayName,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AgentStorageBagScreen(
        ownerId: ownerId,
        displayName: displayName,
      ),
    ),
  );
}
