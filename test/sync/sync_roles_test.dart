import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/sync/sync_roles.dart';

/// 主从角色判定矩阵（docs/sync_protocol_spec.md §2.2）。
void main() {
  group('determineRoleAuto', () {
    test('桌面 + 移动：桌面为 hub', () {
      final d = determineRoleAuto(localHubCapable: true, peerHubCapable: false)!;
      expect(d.localRole, SyncDeviceRole.hub);
      expect(d.peerRole, SyncDeviceRole.console);
      expect(d.syncEnabled, isTrue);
    });

    test('移动 + 桌面：移动为 console', () {
      final d =
          determineRoleAuto(localHubCapable: false, peerHubCapable: true)!;
      expect(d.localRole, SyncDeviceRole.console);
      expect(d.peerRole, SyncDeviceRole.hub);
      expect(d.syncEnabled, isTrue);
    });

    test('两台手机：不确立主从、不开同步', () {
      final d =
          determineRoleAuto(localHubCapable: false, peerHubCapable: false)!;
      expect(d.localRole, SyncDeviceRole.none);
      expect(d.peerRole, SyncDeviceRole.none);
      expect(d.syncEnabled, isFalse);
    });

    test('双桌面：返回 null 交给用户选择', () {
      expect(
          determineRoleAuto(localHubCapable: true, peerHubCapable: true),
          isNull);
    });
  });

  group('decideForBothDesktops', () {
    test('responder 默认 hub；选择结果互补一致', () {
      final a = decideForBothDesktops(localIsHub: true);
      expect(a.localRole, SyncDeviceRole.hub);
      expect(a.peerRole, SyncDeviceRole.console);
      expect(a.syncEnabled, isTrue);

      final b = decideForBothDesktops(localIsHub: false);
      expect(b.localRole, SyncDeviceRole.console);
      expect(b.peerRole, SyncDeviceRole.hub);

      // 同一选择下两侧计算互补：responder=hub ⟺ initiator=console
      expect(a.peerRole, b.localRole);
    });
  });

  test('旧版 App 兜底：不定主从', () {
    expect(kRoleUndecidable.localRole, SyncDeviceRole.none);
    expect(kRoleUndecidable.syncEnabled, isFalse);
  });

  test('SyncDeviceRole JSON 往返', () {
    for (final r in SyncDeviceRole.values) {
      expect(SyncDeviceRole.fromJson(r.toJson()), r);
    }
    expect(SyncDeviceRole.fromJson(null), isNull);
    expect(SyncDeviceRole.fromJson('garbage'), isNull);
  });
}
