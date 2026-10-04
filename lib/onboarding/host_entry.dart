import 'package:shared_preferences/shared_preferences.dart';

import '../peer/pairing_endpoints.dart';
import '../storage/pouch_session.dart';

/// 本机 `shepaw` 现在处于哪种状态。
enum LocalCliStatus { running, installedStopped, notInstalled }

/// 这台电脑把主机放在哪里。记在本机，不进袋子。
enum HostMode {
  unset,
  thisComputer,
  remote;

  static HostMode fromStorage(String? raw) {
    for (final mode in HostMode.values) {
      if (mode.name == raw) return mode;
    }
    return HostMode.unset;
  }
}

/// 解锁之后去哪。
sealed class HostEntry {
  const HostEntry({this.recordMode});

  /// 非空时调用方把 `host_mode` 写成这个值。
  final HostMode? recordMode;
}

class EnterHome extends HostEntry {
  const EnterHome({super.recordMode});
}

class AutoLocal extends HostEntry {
  const AutoLocal({required this.needsStart, super.recordMode});

  final bool needsStart;
}

class ShowHostSetup extends HostEntry {
  const ShowHostSetup({super.recordMode});
}

class ShowPouchChooser extends HostEntry {
  const ShowPouchChooser({super.recordMode});
}

/// 储物袋选择页的路由参数。`switching` 时不自动进入唯一的那只袋子。
class PouchLoginArgs {
  const PouchLoginArgs({
    this.switching = false,
    this.hostUnresponsive = false,
    this.hostPeerId,
  });

  final bool switching;

  /// 本机主机地址已经改回环，但 8 秒内没有连上。
  final bool hostUnresponsive;

  /// 刚配上的主机。储物袋页优先选中它。
  final String? hostPeerId;
}

class HostModeStore {
  static const key = 'host_mode';

  static Future<HostMode> read() async {
    final prefs = await SharedPreferences.getInstance();
    return HostMode.fromStorage(prefs.getString(key));
  }

  static Future<void> write(HostMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, mode.name);
  }
}

/// 自上而下命中即返回。`unset` 会带上要写回的 [HostEntry.recordMode]。
HostEntry resolveHostEntry({
  required bool isDesktop,
  required HostMode mode,
  required LocalCliStatus cli,
  required PouchSession? session,
  required int nowMs,
  String? localCliFingerprint,
  String? sessionHostFingerprint,
}) {
  final loggedIn = session != null && session.isLoggedIn(nowMs);
  if (!isDesktop) {
    return loggedIn ? const EnterHome() : const ShowPouchChooser();
  }
  if (mode == HostMode.remote) {
    return loggedIn ? const EnterHome() : const ShowPouchChooser();
  }

  if (mode == HostMode.unset && cli == LocalCliStatus.notInstalled) {
    final host = sessionHostFingerprint?.trim() ?? '';
    final hostIsLocal = sameFingerprint(localCliFingerprint, host);
    if (loggedIn && host.isNotEmpty && !hostIsLocal) {
      return const EnterHome(recordMode: HostMode.remote);
    }
    return const ShowHostSetup();
  }

  final record =
      mode == HostMode.unset ? HostMode.thisComputer : null;
  switch (cli) {
    case LocalCliStatus.notInstalled:
      return ShowHostSetup(recordMode: record);
    case LocalCliStatus.installedStopped:
      return AutoLocal(needsStart: true, recordMode: record);
    case LocalCliStatus.running:
      final hostIsLocal =
          sameFingerprint(localCliFingerprint, sessionHostFingerprint);
      if (loggedIn && hostIsLocal) {
        return EnterHome(recordMode: record);
      }
      return AutoLocal(needsStart: false, recordMode: record);
  }
}
