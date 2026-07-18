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
  required Widget fallback,
}) {
  return Image.file(
    File(path),
    width: width,
    height: height,
    fit: fit,
    errorBuilder: (_, __, ___) => fallback,
  );
}
