import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 通用头像图片组件，支持 SVG、光栅图（PNG/JPG/GIF/WEBP）、本地文件和网络 URL。
///
/// 使用方式：
/// ```dart
/// AvatarImage(
///   avatar: agent.avatar,
///   size: 40,
///   borderRadius: 10,
///   fallback: Text('A', style: TextStyle(fontSize: 20)),
/// )
/// ```
class AvatarImage extends StatelessWidget {
  /// 头像路径：本地文件路径、网络 URL 或 null。
  final String avatar;

  /// 头像尺寸（宽高相同）。
  final double size;

  /// 圆角半径。
  final double borderRadius;

  /// 加载失败时的兜底 widget。
  final Widget fallback;

  /// 图片填充方式，默认 BoxFit.cover。
  final BoxFit fit;

  const AvatarImage({
    super.key,
    required this.avatar,
    required this.size,
    required this.borderRadius,
    required this.fallback,
    this.fit = BoxFit.cover,
  });

  /// 判断路径是否为 SVG 格式（兼容带 query string 的 URL）。
  static bool isSvg(String path) {
    final lower = path.toLowerCase();
    final pathWithoutQuery = lower.split('?').first;
    return pathWithoutQuery.endsWith('.svg');
  }

  /// 判断路径是否为本地文件。
  static bool isLocalFile(String path) {
    return path.startsWith('/') && !path.startsWith('//');
  }

  /// 判断路径是否为网络 URL。
  static bool isNetworkUrl(String path) {
    return path.startsWith('http://') || path.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = isLocalFile(avatar);
    final isNetwork = isNetworkUrl(avatar);

    if (!isLocal && !isNetwork) {
      // 既不是本地文件也不是网络 URL，返回兜底
      return fallback;
    }

    final Widget imageWidget;

    if (isSvg(avatar)) {
      // SVG 格式 → flutter_svg
      imageWidget = SizedBox(
        width: size,
        height: size,
        child: isLocal
            ? SvgPicture.file(
                File(avatar),
                width: size,
                height: size,
                fit: fit,
                placeholderBuilder: (_) => fallback,
              )
            : SvgPicture.network(
                avatar,
                width: size,
                height: size,
                fit: fit,
                placeholderBuilder: (_) => fallback,
              ),
      );
    } else {
      // 光栅图（PNG/JPG/GIF/WEBP）→ Image widget
      imageWidget = isLocal
          ? Image.file(
              File(avatar),
              width: size,
              height: size,
              fit: fit,
              errorBuilder: (_, __, ___) => fallback,
            )
          : Image.network(
              avatar,
              width: size,
              height: size,
              fit: fit,
              errorBuilder: (_, __, ___) => fallback,
            );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: imageWidget,
    );
  }
}
