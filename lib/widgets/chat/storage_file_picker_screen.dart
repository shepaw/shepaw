import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../screens/storage_browser_screen.dart';
import '../../storage/host_pouch_target.dart';

/// 从当前登录的储物袋里选文件，供聊天附件、玉简附件使用。
///
/// 和储物袋页一样走 [HostPouchTarget]：袋子在主机上时列主机那一份，
/// 不列这台 App 自己的本地目录。
class StorageFilePickerScreen extends StatefulWidget {
  const StorageFilePickerScreen({
    super.key,
    this.maxSelection = 9,
  });

  /// 最多可选文件数（通常为聊天待发送队列剩余容量）。
  final int maxSelection;

  @override
  State<StorageFilePickerScreen> createState() =>
      _StorageFilePickerScreenState();
}

class _StorageFilePickerScreenState extends State<StorageFilePickerScreen> {
  HostPouchTarget? _pouch;

  @override
  void initState() {
    super.initState();
    unawaited(_resolvePouch());
  }

  Future<void> _resolvePouch() async {
    final target = await HostPouchTarget.resolve();
    if (!mounted) return;
    setState(() => _pouch = target);
  }

  @override
  Widget build(BuildContext context) {
    final pouch = _pouch;
    if (pouch == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final l10n = AppLocalizations.of(context);
    return StorageBrowserScreen(
      pickForAttachment: true,
      maxPickCount: widget.maxSelection,
      title: l10n.chat_storageFilePickerTitle,
      readOnly: true,
      deviceId: pouch.isRemote ? pouch.deviceId : null,
      peerId: pouch.peerId,
      ownHostPouch: pouch.isRemote,
    );
  }
}
