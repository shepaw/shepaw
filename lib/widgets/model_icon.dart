import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Brand glyph used to represent AI models throughout the app.
///
/// Renders an original interlocking-ring mark from [assets/icons/model_glyph.svg]
/// and tints it so it adapts to light/dark themes just like a Material [Icon].
class ModelIcon extends StatelessWidget {
  final double size;
  final Color? color;

  const ModelIcon({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return SvgPicture.asset(
      'assets/icons/model_glyph.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(resolved, BlendMode.srcIn),
    );
  }
}
