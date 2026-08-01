import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'avatar_local_file.dart'
    if (dart.library.html) 'avatar_local_file_web.dart' as local_file;

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

  /// 判断路径是否为打包资源（assets 内置图）。
  static bool isAsset(String path) {
    return path.startsWith('assets/');
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = isLocalFile(avatar);
    final isNetwork = isNetworkUrl(avatar);
    final isBundledAsset = isAsset(avatar);

    if (isBundledAsset) {
      final Widget assetWidget = isSvg(avatar)
          ? SvgPicture.asset(
              avatar,
              width: size,
              height: size,
              fit: fit,
              placeholderBuilder: (_) => fallback,
            )
          : Image.asset(
              avatar,
              width: size,
              height: size,
              fit: fit,
              errorBuilder: (_, __, ___) => fallback,
            );
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: SizedBox(width: size, height: size, child: assetWidget),
      );
    }

    if (!isLocal && !isNetwork) {
      // Emoji / 短文本默认头像：铺满区域，避免四周大片空隙。
      return _EmojiAvatar(
        avatar: avatar,
        size: size,
        borderRadius: borderRadius,
        fallback: fallback,
      );
    }

    final Widget imageWidget;

    if (isSvg(avatar)) {
      imageWidget = isLocal
          ? local_file.svgFile(
              avatar,
              width: size,
              height: size,
              fit: fit,
              placeholder: fallback,
            )
          : SvgPicture.network(
              avatar,
              width: size,
              height: size,
              fit: fit,
              placeholderBuilder: (_) => fallback,
            );
    } else {
      imageWidget = isLocal
          ? local_file.rasterFile(
              avatar,
              width: size,
              height: size,
              fit: fit,
              fallback: fallback,
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
      child: SizedBox(width: size, height: size, child: imageWidget),
    );
  }
}

/// 将 emoji 默认头像放大到接近 [size]，减少灰底空隙。
class _EmojiAvatar extends StatelessWidget {
  final String avatar;
  final double size;
  final double borderRadius;
  final Widget fallback;

  const _EmojiAvatar({
    required this.avatar,
    required this.size,
    required this.borderRadius,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final glyph = avatar.trim();
    if (glyph.isEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(child: fallback),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          // height: 1 去掉 emoji 字体多余行高；字号接近容器边长以铺满。
          child: Text(
            glyph,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: size * 0.86,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}
