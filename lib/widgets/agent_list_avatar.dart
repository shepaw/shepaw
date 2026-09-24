import 'package:flutter/material.dart';

import 'avatar_image.dart';

/// 列表场景的 agent 头像，样式与对话列表（HomeScreen）保持一致：
/// 中性底板圆角方块内嵌头像图，无头像或加载失败时回落到名称首字母。
///
/// 底板由 [AvatarImage] 统一提供（浅色模式浅灰、深色模式浅灰略暗），
/// 保证「透明底 + 近黑描边」的引擎 logo 在深色模式下依然可见。
class AgentListAvatar extends StatelessWidget {
  /// 头像路径：本地文件路径、网络 URL、emoji 或空字符串。
  final String avatar;

  /// agent 名称，用于无头像时的首字母兜底。
  final String name;

  /// 头像尺寸（宽高相同），默认 40。
  final double size;

  const AgentListAvatar({
    super.key,
    required this.avatar,
    required this.name,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.25;
    return AvatarImage(
      avatar: avatar,
      size: size,
      borderRadius: radius,
      fallback: Text(
        name.isNotEmpty ? name[0] : 'A',
        style: TextStyle(fontSize: size * 0.5),
      ),
    );
  }
}
