/// 主从角色判定（docs/sync_protocol_spec.md §2.2）。
///
/// 判定是纯函数：双方各自用同一规则计算，结果必须互补一致；
/// 双桌面场景由 responder（展示二维码方）用户选择，结果经
/// PairingResponse.responderIsHub 带回 initiator。
library;

/// 设备主从角色（paired_peers.device_role 的取值）。
enum SyncDeviceRole {
  hub,
  console,
  none;

  String toJson() => name;

  static SyncDeviceRole? fromJson(String? value) {
    if (value == null) return null;
    for (final r in SyncDeviceRole.values) {
      if (r.name == value) return r;
    }
    return null;
  }
}

/// 角色判定结果。
class RoleDecision {
  const RoleDecision({
    required this.localRole,
    required this.syncEnabled,
  });

  /// 本机角色；对端角色恒为互补（hub↔console，none↔none）。
  final SyncDeviceRole localRole;

  /// 是否开启同步（确立 hub/console 时为 true）。
  final bool syncEnabled;

  SyncDeviceRole get peerRole => switch (localRole) {
        SyncDeviceRole.hub => SyncDeviceRole.console,
        SyncDeviceRole.console => SyncDeviceRole.hub,
        SyncDeviceRole.none => SyncDeviceRole.none,
      };
}

/// 自动判定。双桌面返回 null（需用户选择，见 [decideForBothDesktops]）。
RoleDecision? determineRoleAuto({
  required bool localHubCapable,
  required bool peerHubCapable,
}) {
  if (localHubCapable && !peerHubCapable) {
    // 桌面 + 移动：本机为 hub
    return const RoleDecision(localRole: SyncDeviceRole.hub, syncEnabled: true);
  }
  if (!localHubCapable && peerHubCapable) {
    return const RoleDecision(
        localRole: SyncDeviceRole.console, syncEnabled: true);
  }
  if (!localHubCapable && !peerHubCapable) {
    // 两台手机：不确立主从，保留现有 peer 聊天行为
    return const RoleDecision(localRole: SyncDeviceRole.none, syncEnabled: false);
  }
  return null; // 双桌面
}

/// 双桌面场景的用户选择结果。默认展示二维码的一方（responder）为 hub。
RoleDecision decideForBothDesktops({required bool localIsHub}) {
  return RoleDecision(
    localRole: localIsHub ? SyncDeviceRole.hub : SyncDeviceRole.console,
    syncEnabled: true,
  );
}

/// 对端是旧版 App（未上报设备信息）时的兜底：不定主从、不同步。
const RoleDecision kRoleUndecidable =
    RoleDecision(localRole: SyncDeviceRole.none, syncEnabled: false);
