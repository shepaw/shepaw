import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_theme.dart';
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
///
/// 默认会铺一层中性浅色底板（[AppColors.avatarPlate]）：引擎 logo 多为
/// 「透明底 + 近黑描边」，深色模式下贴在深色页面上会完全看不见。外层若已有
/// 自己的底色（例如群头像的橘色容器），传 `showPlate: false` 让位。
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

  /// 是否铺头像底板，默认 true。外层容器自带底色时传 false。
  final bool showPlate;

  /// 底板颜色，缺省按主题取 [AppColors.avatarPlateFor]。
  final Color? plateColor;

  const AvatarImage({
    super.key,
    required this.avatar,
    required this.size,
    required this.borderRadius,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.showPlate = true,
    this.plateColor,
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

  /// 按显示尺寸 × DPR 计算解码宽度，避免 32px 头像按原图全尺寸解码
  /// （用户上传的大图会放大内存与解码耗时）。SVG 不走位图解码，无需此值。
  static int _cacheWidth(double size) {
    final dpr =
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    return (size * dpr).round();
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
              cacheWidth: _cacheWidth(size),
              errorBuilder: (_, __, ___) => fallback,
            );
      return _shell(context, assetWidget);
    }

    if (!isLocal && !isNetwork) {
      return _shell(context, _emojiContent());
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
              cacheWidth: _cacheWidth(size),
              fallback: fallback,
            )
          : Image.network(
              avatar,
              width: size,
              height: size,
              fit: fit,
              cacheWidth: _cacheWidth(size),
              errorBuilder: (_, __, ___) => fallback,
            );
    }

    return _shell(context, imageWidget);
  }

  /// 统一裁剪 + 铺底板；底板存在时同时给兜底文字/图标一个可读的前景色，
  /// 否则深色模式下「浅色底板 + 浅色首字母」会再次看不清。
  Widget _shell(BuildContext context, Widget child) {
    final plate = showPlate
        ? (plateColor ??
            AppColors.avatarPlateFor(Theme.of(context).brightness))
        : null;

    Widget content = child;
    if (plate != null) {
      content = DefaultTextStyle.merge(
        style: const TextStyle(color: AppColors.onAvatarPlate),
        child: IconTheme.merge(
          data: const IconThemeData(color: AppColors.onAvatarPlate),
          child: child,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: ColoredBox(
          color: plate ?? Colors.transparent,
          child: content,
        ),
      ),
    );
  }

  /// emoji / 短文本默认头像内容：铺满区域，避免四周大片空隙。
  Widget _emojiContent() {
    final glyph = avatar.trim();
    if (glyph.isEmpty) {
      return Center(child: fallback);
    }
    return Center(
      // height: 1 去掉 emoji 字体多余行高；字号接近容器边长以铺满。
      child: Text(
        glyph,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: size * 0.86,
          height: 1.0,
        ),
      ),
    );
  }
}
