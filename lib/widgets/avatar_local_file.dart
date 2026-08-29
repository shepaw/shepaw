import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Local SVG avatar via dart:io [File] (VM / mobile / desktop).
Widget svgFile(
  String path, {
  required double width,
  required double height,
  required BoxFit fit,
  required Widget placeholder,
}) {
  return SvgPicture.file(
    File(path),
    width: width,
    height: height,
    fit: fit,
    placeholderBuilder: (_) => placeholder,
  );
}

/// Local raster avatar via dart:io [File] (VM / mobile / desktop).
Widget rasterFile(
  String path, {
  required double width,
  required double height,
  required BoxFit fit,
  int? cacheWidth,
  required Widget fallback,
}) {
  return Image.file(
    File(path),
    width: width,
    height: height,
    fit: fit,
    // 解码分辨率对齐显示尺寸：头像多为用户上传大图，不限制时按原图
    // 全尺寸解码进内存。
    cacheWidth: cacheWidth,
    errorBuilder: (_, __, ___) => fallback,
  );
}
