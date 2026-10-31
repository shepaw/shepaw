import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/peer_detail_sections.dart';
import 'package:shepaw/peer/peer_device_actions.dart';
import 'package:shepaw/services/contacts_directory.dart';
import 'package:shepaw/storage/store_protocol.dart' show TrustLevel;

void main() {
  group('设备详情按角色显示区块', () {
    test('主机：Agent、引擎、存储、安全、删除都有', () {
      final s = PeerDetailSections.of(
        isHost: true,
        section: ContactSection.host,
        unlistedNode: false,
        hasAgents: true,
      );
      expect(s.showAgents, isTrue);
      expect(s.showEngine, isTrue);
      expect(s.showStorage, isTrue);
      expect(s.showSecurity, isTrue);
      expect(s.showDelete, isTrue);
    });

    test('工作节点：Agent 和引擎有，其余照常', () {
      final s = PeerDetailSections.of(
        isHost: false,
        section: ContactSection.worker,
        unlistedNode: false,
        hasAgents: true,
      );
      expect(s.showAgents, isTrue);
      expect(s.showEngine, isTrue);
      expect(s.showDelete, isTrue);
    });

    test('手机客户端：不显示引擎，但有 Agent 时仍显示 Agent', () {
      final s = PeerDetailSections.of(
        isHost: false,
        section: ContactSection.mobileClient,
        unlistedNode: false,
        hasAgents: false,
      );
      expect(s.showAgents, isFalse);
      expect(s.showEngine, isFalse);
      expect(s.showStorage, isTrue);
      expect(s.showDelete, isTrue);

      final withAgents = PeerDetailSections.of(
        isHost: false,
        section: ContactSection.mobileClient,
        unlistedNode: false,
        hasAgents: true,
      );
      expect(withAgents.showAgents, isTrue);
      expect(withAgents.showEngine, isFalse);
    });

    test('名单没同步回来的节点行：只读，没有删除入口', () {
      final s = PeerDetailSections.of(
        isHost: false,
        section: ContactSection.worker,
        unlistedNode: true,
        hasAgents: true,
      );
      expect(s.showAgents, isTrue);
      expect(s.showEngine, isFalse);
      expect(s.showStorage, isFalse);
      expect(s.showSecurity, isFalse);
      expect(s.showDelete, isFalse);
    });

    test('拿不到通讯录那一行时按 peer 自己的身份兜底', () {
      final worker = PeerDetailSections.of(
        isHost: false,
        section: null,
        unlistedNode: false,
        hasAgents: false,
      );
      // section 为 null 又不是主机，按客户端处理：不显示引擎。
      expect(worker.showEngine, isFalse);
    });
  });

  group('信任级别确认', () {
    test('没选 / 没改动时不动', () {
      expect(
        PeerDeviceActions.shouldApplyTrustChange(
          null,
          TrustLevel.friend,
          true,
        ),
        isFalse,
      );
      expect(
        PeerDeviceActions.shouldApplyTrustChange(
          TrustLevel.friend,
          TrustLevel.friend,
          true,
        ),
        isFalse,
      );
    });

    test('升级成所有者：确认框点空白关掉算取消', () {
      expect(
        PeerDeviceActions.shouldApplyTrustChange(
          TrustLevel.owner,
          TrustLevel.friend,
          null,
        ),
        isFalse,
        reason: '原来这里会照样升级，放宽一台设备的权限',
      );
      expect(
        PeerDeviceActions.shouldApplyTrustChange(
          TrustLevel.owner,
          TrustLevel.friend,
          false,
        ),
        isTrue,
      );
    });

    test('降级成朋友不需要确认', () {
      expect(
        PeerDeviceActions.shouldApplyTrustChange(
          TrustLevel.friend,
          TrustLevel.owner,
          null,
        ),
        isTrue,
      );
    });
  });
}
