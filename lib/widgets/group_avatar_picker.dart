import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_localizations.dart';
import '../services/error_handler_service.dart';
import '../services/local_file_storage_service.dart';
import '../utils/layout_utils.dart';

/// 群头像选择（内置 emoji / 相册 / 拍照 / 移除）。
///
/// 聊天页桌面抽屉编辑与群详情页编辑共用同一份实现——此前两处各抄了一份
/// （含两份逐字相同的 emoji 常量表），改一处就会漏另一处。
///
/// 只负责「选到值」：回调 [onPick] 给出最终头像（emoji 或本地绝对路径），
/// [onRemove] 表示清空；状态由调用方保存（父级 setState / 面板 setEditState）。
class GroupAvatarPicker {
  GroupAvatarPicker._();

  /// 内置候选头像（emoji）。
  static const List<String> builtinAvatars = [
    '🤖', '🦾', '🧠', '💡', '🌟', '⚡', '🔮', '🎯',
    '🚀', '🛸', '🌈', '🔥', '💎', '🎨', '🎭', '🎪',
    '🐱', '🐶', '🦊', '🐼', '🦉', '🦋', '🐝', '🐙',
    '👤', '👩‍💻', '🧑‍🔬', '🧑‍🚀', '🧙', '🥷', '🦸', '🤹',
  ];

  /// 来源选择面板：内置图标 / 相册 / 拍照 /（已有头像时）移除。
  ///
  /// [currentAvatar] 为空时隐藏「移除」。
  static Future<void> showSourceSheet(
    BuildContext context, {
    required String currentAvatar,
    required ValueChanged<String> onPick,
    required VoidCallback onRemove,
  }) {
    final l10n = AppLocalizations.of(context);
    return LayoutUtils.showAdaptivePanel(
      context: context,
      builder: (sheetCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.emoji_emotions_outlined),
            title: Text(l10n.agentDetail_selectBuiltinAvatar),
            onTap: () {
              Navigator.pop(sheetCtx);
              showBuiltinGrid(context, onPick);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.agentDetail_selectFromGallery),
            onTap: () {
              Navigator.pop(sheetCtx);
              pickImage(context, source: ImageSource.gallery, onReady: onPick);
            },
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: Text(l10n.agentDetail_takePhoto),
            onTap: () {
              Navigator.pop(sheetCtx);
              pickImage(context, source: ImageSource.camera, onReady: onPick);
            },
          ),
          if (currentAvatar.isNotEmpty)
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red[400]),
              title: Text(l10n.groupDetail_removeAvatar),
              onTap: () {
                Navigator.pop(sheetCtx);
                onRemove();
              },
            ),
        ],
      ),
    );
  }

  /// 内置 emoji 网格。
  static Future<void> showBuiltinGrid(
    BuildContext context,
    ValueChanged<String> onPick,
  ) {
    final l10n = AppLocalizations.of(context);
    return showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l10n.addAgent_selectAvatar),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: builtinAvatars.length,
            itemBuilder: (context, index) {
              final avatar = builtinAvatars[index];
              return GestureDetector(
                onTap: () {
                  onPick(avatar);
                  Navigator.pop(dialogCtx);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(avatar, style: const TextStyle(fontSize: 32)),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(l10n.common_cancel),
          ),
        ],
      ),
    );
  }

  /// 相册/拍照 → 存入 avatars 目录 → 回调绝对路径。
  ///
  /// 与 agent 头像一致：持久化绝对路径（[AvatarImage] 按 `/` 前缀判本地文件）。
  static Future<void> pickImage(
    BuildContext context, {
    required ImageSource source,
    required ValueChanged<String> onReady,
  }) async {
    final l10n = AppLocalizations.of(context);
    try {
      final XFile? image = await ImagePicker().pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image == null) return;
      final storage = LocalFileStorageService();
      final relativePath = await storage.saveImage(
        File(image.path),
        type: ResourceType.avatars,
      );
      onReady(await storage.getFullPath(relativePath));
    } catch (e) {
      if (!context.mounted) return;
      showTopToast(
        context,
        source == ImageSource.camera
            ? l10n.agentDetail_cameraFailed('$e')
            : l10n.agentDetail_galleryFailed('$e'),
        icon: Icons.error,
        color: Colors.red,
      );
    }
  }
}
