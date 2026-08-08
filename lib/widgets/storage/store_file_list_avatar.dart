import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../storage/store_file_visual.dart';
import '../../storage/store_service.dart';

/// Leading avatar for a store browser file row: image thumbnail or type icon.
class StoreFileListAvatar extends StatefulWidget {
  const StoreFileListAvatar({
    super.key,
    required this.deviceId,
    required this.space,
    required this.path,
    required this.sizeBytes,
  });

  final String deviceId;
  final String space;
  final String path;
  final int sizeBytes;

  @override
  State<StoreFileListAvatar> createState() => _StoreFileListAvatarState();
}

class _StoreFileListAvatarState extends State<StoreFileListAvatar> {
  StoreFileVisualKind _kind = StoreFileVisualKind.generic;
  File? _imageFile;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant StoreFileListAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId ||
        oldWidget.space != widget.space ||
        oldWidget.path != widget.path ||
        oldWidget.sizeBytes != widget.sizeBytes) {
      _loaded = false;
      _imageFile = null;
      _kind = StoreFileVisualKind.generic;
      _load();
    }
  }

  Future<void> _load() async {
    final file = await _resolveLocalFile();
    if (file == null) {
      if (mounted) {
        setState(() {
          _kind = StoreFileVisual.resolveKind(path: widget.path);
          _imageFile = null;
          _loaded = true;
        });
      }
      return;
    }

    List<int> head = const [];
    try {
      head = await file.openRead(0, 16).fold<List<int>>(
            <int>[],
            (prev, chunk) => prev..addAll(chunk),
          );
    } catch (_) {}

    final kind = StoreFileVisual.resolveKind(path: widget.path, head: head);
    // Decode via Image.file + cacheWidth; skip pathological giants only.
    final canThumb = kind == StoreFileVisualKind.image &&
        (widget.sizeBytes <= 0 ||
            widget.sizeBytes <= StoreFileVisual.maxThumbnailSourceBytes);

    if (!mounted) return;
    setState(() {
      _kind = kind;
      _imageFile = canThumb ? file : null;
      _loaded = true;
    });
  }

  Future<File?> _resolveLocalFile() async {
    if (widget.deviceId.isEmpty) return null;
    try {
      final store = await StoreService.instance.localStore();
      final segments = widget.path.split('/').where((s) => s.isNotEmpty);
      final formal = File(p.normalize(p.joinAll([
        store.root.path,
        widget.deviceId,
        widget.space,
        ...segments,
      ])));
      if (await formal.exists()) return formal;

      // Remote-read materialization: <store>/.cache/<device>/<space>/<path>
      final cached = File(p.normalize(p.joinAll([
        store.root.path,
        '.cache',
        widget.deviceId,
        widget.space,
        ...segments,
      ])));
      if (await cached.exists()) return cached;
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_imageFile != null) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      // Only constrain one decode axis so aspect ratio is preserved.
      final cacheSide = (StoreFileVisual.avatarWidth > StoreFileVisual.avatarHeight
              ? StoreFileVisual.avatarWidth
              : StoreFileVisual.avatarHeight) *
          dpr;
      final scheme = Theme.of(context).colorScheme;
      return _frame(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ColoredBox(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            child: Image.file(
              _imageFile!,
              width: StoreFileVisual.avatarWidth,
              height: StoreFileVisual.avatarHeight,
              fit: BoxFit.contain,
              cacheWidth: cacheSide.round(),
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) => _typeIcon(),
            ),
          ),
        ),
      );
    }

    if (!_loaded) {
      return _frame(
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return _typeIcon();
  }

  Widget _frame({required Widget child}) {
    return SizedBox(
      width: StoreFileVisual.avatarWidth,
      height: StoreFileVisual.avatarHeight,
      child: child,
    );
  }

  Widget _typeIcon() {
    final color = StoreFileVisual.iconColorFor(_kind);
    final bg = StoreFileVisual.iconBgFor(_kind);
    return Container(
      width: StoreFileVisual.avatarWidth,
      height: StoreFileVisual.avatarHeight,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        StoreFileVisual.iconFor(_kind),
        color: color,
        size: 24,
      ),
    );
  }
}
