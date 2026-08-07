import 'dart:io';
import 'dart:typed_data';

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
  Uint8List? _thumbnailBytes;
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
      _thumbnailBytes = null;
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
    Uint8List? thumb;
    if (kind == StoreFileVisualKind.image &&
        widget.sizeBytes > 0 &&
        widget.sizeBytes <= StoreFileVisual.maxThumbnailBytes) {
      try {
        thumb = await file.readAsBytes();
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _kind = kind;
      _thumbnailBytes = thumb;
      _loaded = true;
    });
  }

  Future<File?> _resolveLocalFile() async {
    if (widget.deviceId.isEmpty) return null;
    try {
      final store = await StoreService.instance.localStore();
      final abs = p.joinAll([
        store.root.path,
        widget.deviceId,
        widget.space,
        ...widget.path.split('/'),
      ]);
      final file = File(abs);
      if (await file.exists()) return file;
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbnailBytes != null) {
      return _frame(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            _thumbnailBytes!,
            width: StoreFileVisual.avatarWidth,
            height: StoreFileVisual.avatarHeight,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _typeIcon(),
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
