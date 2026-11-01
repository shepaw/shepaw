import 'package:flutter/material.dart';

import 'gate_navigator.dart';

/// 旧的入口。判断和分派已经搬到 [GateNavigator]，这里只是转发。
///
/// TODO(L4)：`login_screen.dart` 和 `host_setup_screen.dart` 改成直接调
/// [GateNavigator.go] 之后删掉本文件。
class HostEntryNavigator {
  static Future<void> go(
    BuildContext context, {
    required bool isDesktop,
  }) =>
      GateNavigator.go(context);
}
