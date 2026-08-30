import 'package:flutter/material.dart';

import 'avatar_image.dart';

/// 列表场景的 agent 头像，样式与对话列表（HomeScreen）保持一致：
/// 灰底圆角方块内嵌头像图，无头像或加载失败时回落到名称首字母。
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
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: AvatarImage(
        avatar: avatar,
        size: size,
        borderRadius: radius,
        fallback: Text(
          name.isNotEmpty ? name[0] : 'A',
          style: TextStyle(fontSize: size * 0.5),
        ),
      ),
    );
  }
}
