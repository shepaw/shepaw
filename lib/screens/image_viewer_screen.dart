import 'dart:io';
import 'package:flutter/material.dart';
import '../utils/layout_utils.dart';

/// Data class for an image entry in the gallery.
class ImageGalleryItem {
  final File file;
  final String? title;

  const ImageGalleryItem({required this.file, this.title});
}

/// Full-screen image gallery viewer with swipe navigation, pinch-to-zoom,
/// and an image counter indicator.
///
/// On desktop layouts, also shows clickable previous/next buttons beside
/// the counter in the app bar.
class ImageViewerScreen extends StatefulWidget {
  /// All images available for swiping.
  final List<ImageGalleryItem> images;

  /// The index of the initially displayed image.
  final int initialIndex;

  /// Hero tag prefix for smooth thumbnail-to-fullscreen animation.
  /// The full tag is "$heroTagPrefix_$index".
  final String? heroTagPrefix;

  const ImageViewerScreen({
    Key? key,
    required this.images,
    this.initialIndex = 0,
    this.heroTagPrefix,
  }) : super(key: key);

  /// Convenience constructor for a single image (backward compatible).
  factory ImageViewerScreen.single({
    Key? key,
    required File imageFile,
    String? title,
    String? heroTag,
  }) {
    return ImageViewerScreen(
      key: key,
      images: [ImageGalleryItem(file: imageFile, title: title)],
      initialIndex: 0,
      heroTagPrefix: heroTag,
    );
  }

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.images.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  String? get _currentTitle {
    final item = widget.images[_currentIndex];
    return item.title;
  }

  bool get _hasMultiple => widget.images.length > 1;

  String get _counterText {
    if (!_hasMultiple) return '';
    return '${_currentIndex + 1}/${widget.images.length}';
  }

  void _goTo(int index) {
    if (index < 0 || index >= widget.images.length) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _goPrevious() => _goTo(_currentIndex - 1);

  void _goNext() => _goTo(_currentIndex + 1);

  Widget _buildNavButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
      color: Colors.white,
      disabledColor: Colors.white24,
      splashRadius: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    );
  }

  /// Desktop: previous / next buttons placed to the left of the counter.
  Widget _buildDesktopCounterNav() {
    final canPrevious = _currentIndex > 0;
    final canNext = _currentIndex < widget.images.length - 1;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildNavButton(
          icon: Icons.chevron_left,
          tooltip: 'Previous',
          onPressed: canPrevious ? _goPrevious : null,
        ),
        _buildNavButton(
          icon: Icons.chevron_right,
          tooltip: 'Next',
          onPressed: canNext ? _goNext : null,
        ),
        const SizedBox(width: 4),
        Text(
          _counterText,
          style: const TextStyle(
            fontSize: 13,
            color: Colors.white70,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = LayoutUtils.isDesktopLayout(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            if (_currentTitle != null)
              Expanded(
                child: Text(
                  _currentTitle!,
                  style: const TextStyle(fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (_counterText.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  left: _currentTitle != null ? 8 : 0,
                ),
                child: isDesktop
                    ? _buildDesktopCounterNav()
                    : Text(
                        _counterText,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white70,
                        ),
                      ),
              ),
          ],
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          final item = widget.images[index];
          final imageWidget = InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Center(
              child: Image.file(
                item.file,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.broken_image,
                          color: Colors.white54, size: 64),
                      SizedBox(height: 16),
                      Text(
                        'Failed to load image',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ],
                  );
                },
              ),
            ),
          );

          // Wrap with Hero for the tapped image
          if (widget.heroTagPrefix != null) {
            return Hero(
              tag: '${widget.heroTagPrefix}_$index',
              child: imageWidget,
            );
          }
          return imageWidget;
        },
      ),
    );
  }
}
