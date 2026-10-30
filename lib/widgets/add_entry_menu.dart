import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/add_agent_instance_screen.dart';
import '../peer/screens/peer_pairing_screen.dart';
import '../peer/screens/peer_scan_screen.dart';
import '../screens/create_group_screen.dart';
import '../utils/platform_utils.dart';

/// 「+」菜单里的动作。消息列表和通讯录共用同一份，顺序也一致。
enum AddEntryAction {
  agent,
  group,
  device,
  scan,
}

/// 消息列表页和通讯录页的「+」菜单。
///
/// 以前两处各写一份：顺序不同、图标有的有有的没有、同一个「设备配对」落到
/// 四个不同的页面。现在菜单项和落地逻辑都收在这里。
class AddEntryMenu {
  AddEntryMenu._();

  /// 桌面没有摄像头，扫码入口不出现。按平台判断，不看窗口宽度——
  /// 桌面窄窗口会走移动布局，但一样没有扫码能力。
  static bool get supportsScan => !isDesktopPlatform;

  static List<PopupMenuEntry<AddEntryAction>> items(
    AppLocalizations l10n, {
    required bool showScan,
  }) {
    return [
      _item(
        value: AddEntryAction.agent,
        icon: Icons.smart_toy_outlined,
        label: l10n.home_addAgentInstance,
      ),
      _item(
        value: AddEntryAction.group,
        icon: Icons.group_add,
        label: l10n.home_createGroup,
      ),
      _item(
        value: AddEntryAction.device,
        icon: Icons.devices_outlined,
        label: l10n.home_addDevice,
      ),
      if (showScan)
        _item(
          value: AddEntryAction.scan,
          icon: Icons.qr_code_scanner,
          label: l10n.home_scanConnect,
        ),
    ];
  }

  static PopupMenuItem<AddEntryAction> _item({
    required AddEntryAction value,
    required IconData icon,
    required String label,
  }) {
    return PopupMenuItem<AddEntryAction>(
      value: value,
      height: 44,
      child: Row(
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 15)),
          ),
        ],
      ),
    );
  }

  /// 执行一项。
  ///
  /// [embedded] 为桌面嵌入的中栏时优先走父级回调（在右栏打开）；否则自己
  /// push。[presetNodeId] 是通讯录里「在某个工作节点下添加」用的。
  /// [afterPushed] 在 push 出去的页面关闭后调用，用来刷新列表。
  static Future<void> run(
    BuildContext context,
    AddEntryAction action, {
    required bool embedded,
    VoidCallback? onAddAgentInstance,
    VoidCallback? onCreateGroup,
    VoidCallback? onPairDevice,
    String? presetNodeId,
    void Function(PairedPeer peer)? onPaired,
    VoidCallback? afterPushed,
  }) async {
    Future<void> open(Widget page) async {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => page),
      );
      afterPushed?.call();
    }

    switch (action) {
      case AddEntryAction.agent:
        if (embedded && onAddAgentInstance != null) {
          onAddAgentInstance();
          return;
        }
        await open(AddAgentInstanceScreen(presetNodeId: presetNodeId));
      case AddEntryAction.group:
        if (embedded && onCreateGroup != null) {
          onCreateGroup();
          return;
        }
        await open(const CreateGroupScreen());
      case AddEntryAction.device:
        if (embedded && onPairDevice != null) {
          onPairDevice();
          return;
        }
        // 配对页自带「我连它 / 它连我」两个页签，手动输入在「我连它」里。
        // 桌面没有摄像头，直接落到展示二维码那一页。
        final peer = await PeerPairingScreen.show(
          context,
          initialTab: isDesktopPlatform
              ? PeerPairingTab.beConnected
              : PeerPairingTab.connect,
        );
        afterPushed?.call();
        if (peer != null) onPaired?.call(peer);
      case AddEntryAction.scan:
        await PeerScanScreen.show(context);
        afterPushed?.call();
    }
  }
}
