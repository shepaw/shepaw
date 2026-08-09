import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';

/// Visual / preview classification for store browser list rows.
enum StoreFileVisualKind {
  image,
  audio,
  video,
  pdf,
  document,
  spreadsheet,
  presentation,
  text,
  archive,
  generic,
}

enum StorePreviewKind { image, text, other }

class StoreFileVisual {
  StoreFileVisual._();

  static const avatarWidth = 42.0;
  static const avatarHeight = 50.0;

  /// Soft ceiling for list-row image decode via [Image.file] + cacheWidth.
  /// Far above typical photos; only skips pathological giants.
  static const maxThumbnailSourceBytes = 50 * 1024 * 1024;

  static final RegExp _sha256Leaf =
      RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

  static bool isChatAttachmentPath(String path) {
    final parts = path.split('/');
    if (parts.length == 2 &&
        parts[0] == StoreSpace.chatAttachmentPrefix &&
        _sha256Leaf.hasMatch(parts[1])) {
      return true;
    }
    // runtime/<owner>/<channel>/attachments/<sha256>
    return RuntimePaths.isRuntimeAttachmentPath(path);
  }

  static StoreFileVisualKind resolveKind({
    required String path,
    List<int>? head,
  }) {
    final ext = p.extension(path).toLowerCase();
    if (ext.isNotEmpty) {
      return _kindFromExtension(ext);
    }
    final magic = head == null ? null : kindFromMagicBytes(head);
    return magic ?? StoreFileVisualKind.generic;
  }

  static StorePreviewKind previewKind(String path, {List<int>? head}) {
    switch (resolveKind(path: path, head: head)) {
      case StoreFileVisualKind.image:
        return StorePreviewKind.image;
      case StoreFileVisualKind.text:
        return StorePreviewKind.text;
      default:
        return StorePreviewKind.other;
    }
  }

  static StoreFileVisualKind? kindFromMagicBytes(List<int> head) {
    if (head.length >= 3 &&
        head[0] == 0xFF &&
        head[1] == 0xD8 &&
        head[2] == 0xFF) {
      return StoreFileVisualKind.image;
    }
    if (head.length >= 8 &&
        head[0] == 0x89 &&
        head[1] == 0x50 &&
        head[2] == 0x4E &&
        head[3] == 0x47) {
      return StoreFileVisualKind.image;
    }
    if (head.length >= 6 &&
        head[0] == 0x47 &&
        head[1] == 0x49 &&
        head[2] == 0x46) {
      return StoreFileVisualKind.image;
    }
    if (head.length >= 12 &&
        head[0] == 0x52 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x46 &&
        head[8] == 0x57 &&
        head[9] == 0x45 &&
        head[10] == 0x42 &&
        head[11] == 0x50) {
      return StoreFileVisualKind.image;
    }
    if (head.length >= 4 &&
        head[0] == 0x25 &&
        head[1] == 0x50 &&
        head[2] == 0x44 &&
        head[3] == 0x46) {
      return StoreFileVisualKind.pdf;
    }
    if (head.length >= 4 &&
        head[0] == 0x52 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x46) {
      final tag = String.fromCharCodes(head.length >= 12 ? head.sublist(8, 12) : []);
      if (tag == 'WAVE') return StoreFileVisualKind.audio;
      if (tag == 'AVI ') return StoreFileVisualKind.video;
    }
    if (head.length >= 3 &&
        head[0] == 0x49 &&
        head[1] == 0x44 &&
        head[2] == 0x33) {
      return StoreFileVisualKind.audio;
    }
    if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
      return StoreFileVisualKind.audio;
    }
    if (head.length >= 4 &&
        head[0] == 0x1A &&
        head[1] == 0x45 &&
        head[2] == 0xDF &&
        head[3] == 0xA3) {
      return StoreFileVisualKind.video;
    }
    if (head.length >= 8 &&
        head[4] == 0x66 &&
        head[5] == 0x74 &&
        head[6] == 0x79 &&
        head[7] == 0x70) {
      return StoreFileVisualKind.video;
    }
    if (head.length >= 2 && head[0] == 0x50 && head[1] == 0x4B) {
      return StoreFileVisualKind.archive;
    }
    return null;
  }

  static StoreFileVisualKind _kindFromExtension(String ext) {
    switch (ext) {
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.webp':
      case '.bmp':
      case '.heic':
      case '.heif':
        return StoreFileVisualKind.image;
      case '.mp3':
      case '.wav':
      case '.m4a':
      case '.aac':
      case '.ogg':
      case '.flac':
        return StoreFileVisualKind.audio;
      case '.mp4':
      case '.mov':
      case '.avi':
      case '.mkv':
      case '.webm':
        return StoreFileVisualKind.video;
      case '.pdf':
        return StoreFileVisualKind.pdf;
      case '.doc':
      case '.docx':
      case '.rtf':
        return StoreFileVisualKind.document;
      case '.xls':
      case '.xlsx':
      case '.csv':
        return StoreFileVisualKind.spreadsheet;
      case '.ppt':
      case '.pptx':
        return StoreFileVisualKind.presentation;
      case '.txt':
      case '.md':
      case '.markdown':
      case '.json':
      case '.log':
      case '.yaml':
      case '.yml':
      case '.xml':
      case '.html':
      case '.htm':
      case '.dart':
      case '.py':
      case '.js':
      case '.ts':
      case '.swift':
      case '.kt':
      case '.java':
      case '.go':
      case '.rs':
      case '.c':
      case '.h':
      case '.cpp':
      case '.cc':
      case '.css':
      case '.sh':
        return StoreFileVisualKind.text;
      case '.zip':
      case '.rar':
      case '.7z':
      case '.tar':
      case '.gz':
        return StoreFileVisualKind.archive;
      default:
        return StoreFileVisualKind.generic;
    }
  }

  static IconData iconFor(StoreFileVisualKind kind) {
    return switch (kind) {
      StoreFileVisualKind.image => Icons.image_outlined,
      StoreFileVisualKind.audio => Icons.audiotrack_outlined,
      StoreFileVisualKind.video => Icons.videocam_outlined,
      StoreFileVisualKind.pdf => Icons.picture_as_pdf_outlined,
      StoreFileVisualKind.document => Icons.description_outlined,
      StoreFileVisualKind.spreadsheet => Icons.table_chart_outlined,
      StoreFileVisualKind.presentation => Icons.slideshow_outlined,
      StoreFileVisualKind.text => Icons.notes_outlined,
      StoreFileVisualKind.archive => Icons.folder_zip_outlined,
      StoreFileVisualKind.generic => Icons.insert_drive_file_outlined,
    };
  }

  static Color iconColorFor(StoreFileVisualKind kind) {
    return switch (kind) {
      StoreFileVisualKind.image => const Color(0xFF43A047),
      StoreFileVisualKind.audio => const Color(0xFF8E24AA),
      StoreFileVisualKind.video => const Color(0xFFE53935),
      StoreFileVisualKind.pdf => const Color(0xFFD32F2F),
      StoreFileVisualKind.document => const Color(0xFF5B9BD5),
      StoreFileVisualKind.spreadsheet => const Color(0xFF2E7D32),
      StoreFileVisualKind.presentation => const Color(0xFFF57C00),
      StoreFileVisualKind.text => const Color(0xFF546E7A),
      StoreFileVisualKind.archive => const Color(0xFF795548),
      StoreFileVisualKind.generic => const Color(0xFF5B9BD5),
    };
  }

  static Color iconBgFor(StoreFileVisualKind kind) {
    return iconColorFor(kind).withValues(alpha: 0.12);
  }

  static String kindLabel(AppLocalizations l10n, StoreFileVisualKind kind) {
    return switch (kind) {
      StoreFileVisualKind.image => l10n.storage_fileKindImage,
      StoreFileVisualKind.audio => l10n.storage_fileKindAudio,
      StoreFileVisualKind.video => l10n.storage_fileKindVideo,
      StoreFileVisualKind.pdf => l10n.storage_fileKindPdf,
      StoreFileVisualKind.document => l10n.storage_fileKindDocument,
      StoreFileVisualKind.spreadsheet => l10n.storage_fileKindSpreadsheet,
      StoreFileVisualKind.presentation => l10n.storage_fileKindPresentation,
      StoreFileVisualKind.text => l10n.storage_fileKindText,
      StoreFileVisualKind.archive => l10n.storage_fileKindArchive,
      StoreFileVisualKind.generic => l10n.storage_fileKindFile,
    };
  }

  static String displayName(
    AppLocalizations l10n,
    String path, {
    StoreFileVisualKind? kind,
  }) {
    final leaf = p.basename(path);
    if (!isChatAttachmentPath(path)) return leaf;
    final resolved = kind ?? resolveKind(path: path);
    final shortHash =
        leaf.length > 8 ? '${leaf.substring(0, 8)}…' : leaf;
    return l10n.storage_chatAttachmentLabel(
      kindLabel(l10n, resolved),
      shortHash,
    );
  }
}
