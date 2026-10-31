import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/logger_service.dart';
import 'models/paired_peer.dart';
import 'pouch_pair.dart';
import 'services/peer_storage_service.dart';

/// 设备上的操作：改备注、删除配对。
///
/// 通讯录列表和设备详情原来是两份复制粘贴的实现，连弹窗标题都不一样。
/// 这里统一一份，两处都调用它。
class PeerDeviceActions {
  PeerDeviceActions._();

  /// 改备注。返回改后的名字；没改动或改不动时返回 null。
  ///
  /// 主机名单里的设备不在本机 `paired_peers` 表里，改不动；主机侧也没有
  /// 重命名帧，所以这里直接告诉用户不支持，不弹一个改了也没用的输入框。
  static Future<String?> rename(
    BuildContext context,
    PairedPeer peer,
  ) async {
    final l10n = AppLocalizations.of(context);
    final storage = PeerStorageService();
    PairedPeer? local;
    try {
      local = await storage.getPeerById(peer.id);
    } catch (e) {
      LoggerService().error('read peer failed', tag: 'PeerDevice', error: e);
    }
    if (local == null) {
      _snack(context, l10n.peerDevice_renameUnsupported);
      return null;
    }

    final newName = await _showRenameDialog(context, l10n, local.deviceName);
    if (newName == null || newName.isEmpty || newName == local.deviceName) {
      return null;
    }

    final rows = await storage.updateDeviceName(peer.id, newName);
    if (rows == 0) {
      _snack(context, l10n.peerDevice_renameFailed);
      return null;
    }
    return newName;
  }

  /// 删除配对。确认文案按角色区分：删主机和删本机都是大动作。
  ///
  /// [isHost] 这台设备是主机；[isThisDevice] 它是本 App / 这台电脑。
  static Future<bool> confirmDelete(
    BuildContext context,
    PairedPeer peer, {
    required bool isHost,
    required bool isThisDevice,
  }) async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.peerSettings_deletePairing),
        content: Text(
          isHost
              ? l10n.peerSettings_deleteHostConfirm(peer.deviceName)
              : isThisDevice
                  ? l10n.peerSettings_deleteSelfConfirm(peer.deviceName)
                  : l10n.peerSettings_deleteConfirm(peer.deviceName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.common_delete),
          ),
        ],
      ),
    );
    return confirm == true;
  }

  /// 执行删除。返回是否删掉了。
  static Future<bool> delete(BuildContext context, PairedPeer peer) async {
    final l10n = AppLocalizations.of(context);
    try {
      await PouchPairing.remove(peer);
      return true;
    } catch (e) {
      LoggerService().error('delete peer failed', tag: 'PeerDevice', error: e);
      _snack(context, l10n.peerSettings_deleteFailed('$e'));
      return false;
    }
  }

  static Future<String?> _showRenameDialog(
    BuildContext context,
    AppLocalizations l10n,
    String currentName,
  ) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => _RenameDialog(l10n: l10n, currentName: currentName),
    );
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.l10n, required this.currentName});

  final AppLocalizations l10n;
  final String currentName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.l10n.peerSettings_editAliasTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: widget.l10n.peerSettings_editAliasHint,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(widget.l10n.common_save),
        ),
      ],
    );
  }
}
