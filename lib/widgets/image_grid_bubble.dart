import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/local_file_storage_service.dart';
import '../screens/image_viewer_screen.dart';

/// Displays a grid of image thumbnails for grouped consecutive image messages.
/// Tapping any thumbnail opens the full-screen gallery viewer positioned at
/// that image.
class ImageGridBubble extends StatefulWidget {
  /// The grouped image messages to display as a grid.
  final List<Message> imageMessages;
  final bool isMyMessage;

  /// All image messages in the conversation, for gallery navigation.
  final List<Message> allImageMessages;

  /// Maps message id -> index in [allImageMessages].
  final Map<String, int> imageIndexMap;

  const ImageGridBubble({
    Key? key,
    required this.imageMessages,
    required this.isMyMessage,
    this.allImageMessages = const [],
    this.imageIndexMap = const {},
  }) : super(key: key);

  @override
  State<ImageGridBubble> createState() => _ImageGridBubbleState();
}

class _ImageGridBubbleState extends State<ImageGridBubble> {
  final _storageService = LocalFileStorageService();

  /// Resolved image files keyed by message index in [imageMessages].
  final Map<int, File> _imageFiles = {};

  /// Decoded thumbnail bytes for pending images (no local file yet).
  final Map<int, Uint8List> _thumbnailBytes = {};

  bool _loading = true;

  static const int _maxDisplay = 9;
  static const int _overflowShowCount = 8;
  static const double _thumbSize = 80.0;
  static const double _thumbSpacing = 4.0;
  static const int _crossAxisCount = 3;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    final futures = <Future<void>>[];
    for (int i = 0; i < widget.imageMessages.length; i++) {
      futures.add(_loadSingleImage(i));
    }
    await Future.wait(futures);
    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _loadSingleImage(int index) async {
    final msg = widget.imageMessages[index];
    final relativePath = msg.metadata?['path'] as String?;
    if (relativePath == null) {
      // No local file yet — try decoding thumbnail_base64 for pending images
      final thumbB64 = msg.metadata?['thumbnail_base64'] as String?;
      if (thumbB64 != null && thumbB64.isNotEmpty) {
        try {
          _thumbnailBytes[index] = base64Decode(thumbB64);
        } catch (_) {}
      }
      return;
    }

    try {
      final fullPath = await _storageService.getFullPath(relativePath);
      final file = File(fullPath);
      if (await file.exists()) {
        _imageFiles[index] = file;
      }
    } catch (_) {
      // Skip images that can't be resolved
    }
  }

  Future<void> _openViewer(int tappedIndex) async {
    // Build gallery items from all image messages in the conversation
    final galleryItems = <ImageGalleryItem>[];

    if (widget.allImageMessages.isNotEmpty) {
      for (final msg in widget.allImageMessages) {
        final path = msg.metadata?['path'] as String?;
        if (path == null) continue;
        try {
          final fullPath = await _storageService.getFullPath(path);
          final file = File(fullPath);
          if (await file.exists()) {
            galleryItems.add(ImageGalleryItem(
              file: file,
              title: msg.metadata?['name'] as String?,
            ));
          }
        } catch (_) {
          // Skip images that can't be resolved
        }
      }
    }

    // Fallback: show only the tapped image if gallery building failed
    if (galleryItems.isEmpty) {
      final file = _imageFiles[tappedIndex];
      if (file == null) return;
      galleryItems.add(ImageGalleryItem(
        file: file,
        title: widget.imageMessages[tappedIndex].metadata?['name'] as String?,
      ));
    }

    // Determine the gallery index for the tapped image
    final tappedMsg = widget.imageMessages[tappedIndex];
    int actualIndex = widget.imageIndexMap[tappedMsg.id] ?? 0;
    actualIndex = actualIndex.clamp(0, galleryItems.length - 1);

    if (!mounted) return;

    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) {
          return ImageViewerScreen(
            images: galleryItems,
            initialIndex: actualIndex,
            heroTagPrefix: 'chat_image',
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 180,
        height: 120,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final totalCount = widget.imageMessages.length;
    final hasOverflow = totalCount > _maxDisplay;
    final displayCount = hasOverflow ? _overflowShowCount + 1 : totalCount;
    final overflowCount = totalCount - _overflowShowCount;

    // Calculate grid width based on actual column count
    final actualColumns = displayCount < _crossAxisCount ? displayCount : _crossAxisCount;
    final gridWidth = actualColumns * _thumbSize + (actualColumns - 1) * _thumbSpacing;

    return SizedBox(
      width: gridWidth,
      child: Wrap(
        spacing: _thumbSpacing,
        runSpacing: _thumbSpacing,
        children: List.generate(displayCount, (i) {
          // Last cell is the "+N" overflow indicator
          if (hasOverflow && i == _overflowShowCount) {
            return _buildOverflowThumb(overflowCount);
          }
          return _buildThumb(i);
        }),
      ),
    );
  }

  Widget _buildThumb(int index) {
    final file = _imageFiles[index];
    final thumbBytes = _thumbnailBytes[index];

    return GestureDetector(
      onTap: () => _openViewer(index),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: _thumbSize,
          height: _thumbSize,
          child: file != null
              ? Image.file(
                  file,
                  fit: BoxFit.cover,
                  cacheWidth: 160,
                  cacheHeight: 160,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.broken_image, color: Colors.grey, size: 24),
                    );
                  },
                )
              : thumbBytes != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(
                          thumbBytes,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              color: Colors.grey[300],
                              child: const Icon(Icons.image, color: Colors.grey, size: 24),
                            );
                          },
                        ),
                        Container(
                          color: Colors.black26,
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.download_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ],
                    )
                  : Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.broken_image, color: Colors.grey, size: 24),
                    ),
        ),
      ),
    );
  }

  Widget _buildOverflowThumb(int overflowCount) {
    // Show the 9th image (index 8) as the background with a dark overlay
    final file = _imageFiles[_overflowShowCount];

    return GestureDetector(
      onTap: () => _openViewer(_overflowShowCount),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: _thumbSize,
          height: _thumbSize,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (file != null)
                Image.file(
                  file,
                  fit: BoxFit.cover,
                  cacheWidth: 160,
                  cacheHeight: 160,
                )
              else
                Container(color: Colors.grey[400]),
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: Text(
                  '+$overflowCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
