import '../services/she_service.dart';
import '../storage/pouch_role.dart';

/// 这一进程是不是储物袋主机。App 默认不是，主机在 agent-hub 上。
class PouchDutyState {
  PouchDutyState._();

  static bool isHost = false;

  static void bind(PouchRole role) {
    isHost = role.isHost;
  }
}

/// 客户端只留本机才有的能力。惜宝、时钟和数据面都在主机上。
class PouchDuties {
  PouchDuties._();

  /// 客户端可在本机执行的 CLI 命名空间。`os` 覆盖定位、文件和本机命令。
  static const clientNamespaces = <String>{'os', 'vision', 'help'};

  static const dataPlaneMessage = '数据面命令在储物袋主机上执行';

  static bool runsLocalShe(bool isHost) => isHost;

  static bool runsScheduler(bool isHost) => isHost;

  /// 主机上的时钟不随 App 进后台停。客户端不启动时钟，所以也不暂停。
  static bool schedulerFollowsAppBackground(bool isHost) => !isHost;

  static bool cliAllowed({required bool isHost, required String namespace}) {
    if (isHost) return true;
    return clientNamespaces.contains(namespace.trim());
  }

  /// 客户端把主机的惜宝落在固定 id 上，界面仍按这个 id 找她。
  /// 本机已经有一条自己的惜宝时不覆盖。
  static bool adoptHostSheRow({
    required bool isHost,
    required String? hostPeerId,
    required String peerId,
    required String remoteAgentId,
    required bool sheIdTakenBySomeoneElse,
  }) {
    if (isHost || sheIdTakenBySomeoneElse) return false;
    final host = hostPeerId?.trim() ?? '';
    if (host.isEmpty || host != peerId.trim()) return false;
    return remoteAgentId.trim() == SheService.sheId;
  }
}
