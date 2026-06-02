import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/remote_agent.dart';
import '../services/logger_service.dart';
import '../services/local_file_storage_service.dart';
import '../services/local_database_service.dart';
import '../services/file_download_service.dart';
import '../services/ws_file_transfer_service.dart';
import '../services/acp_agent_connection.dart';
import '../services/chat_service.dart';
import '../services/peer_key_utils.dart';
import '../service_locator.dart' show acpServerOrNull;
import '../screens/image_viewer_screen.dart';

/// Displays image messages with three download states:
/// - **pending**: shows base64 thumbnail (or placeholder) with a download icon overlay
/// - **downloading**: shows thumbnail with a circular progress indicator
/// - **completed**: shows the full-res local image; tap opens the gallery viewer
class ImageMessageBubble extends StatefulWidget {
  final Message message;
  final bool isMyMessage;

  /// All image messages in the conversation, used for gallery navigation.
  final List<Message> allImageMessages;

  /// Index of this message within [allImageMessages].
  final int imageIndex;

  const ImageMessageBubble({
    Key? key,
    required this.message,
    required this.isMyMessage,
    this.allImageMessages = const [],
    this.imageIndex = 0,
  }) : super(key: key);

  @override
  State<ImageMessageBubble> createState() => _ImageMessageBubbleState();
}

class _ImageMessageBubbleState extends State<ImageMessageBubble> {
  /// One of 'pending', 'downloading', 'completed'.
  String _downloadStatus = 'completed';
  double _progress = 0.0;
  File? _imageFile;
  Uint8List? _thumbnailBytes;

  @override
  void initState() {
    super.initState();
    _initState();
  }

  void _initState() {
    final meta = widget.message.metadata;
    // Default to 'completed' for backward compat with existing messages
    _downloadStatus = meta?['download_status'] as String? ?? 'completed';

    // Decode thumbnail if available
    final thumbB64 = meta?['thumbnail_base64'] as String?;
    if (thumbB64 != null && thumbB64.isNotEmpty) {
      try {
        _thumbnailBytes = base64Decode(thumbB64);
      } catch (_) {}
    }

    if (_downloadStatus == 'completed') {
      _loadLocalImage();
    }
  }

  Future<void> _loadLocalImage() async {
    final relativePath = widget.message.metadata?['path'] as String?;
    if (relativePath == null) {
      // completed but no path — treat as error / show placeholder
      if (mounted) {
        setState(() {
          _imageFile = null;
        });
      }
      return;
    }

    try {
      final fullPath =
          await LocalFileStorageService().getFullPath(relativePath);
      final file = File(fullPath);
      if (await file.exists()) {
        if (mounted) {
          setState(() {
            _imageFile = file;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _startDownload() async {
    final url = widget.message.metadata?['source_url'] as String?;
    final fileId = widget.message.metadata?['file_id'] as String?;
    if ((url == null || url.isEmpty) && (fileId == null || fileId.isEmpty)) return;

    setState(() {
      _downloadStatus = 'downloading';
      _progress = 0.0;
    });

    try {
      String? relativePath;

      // 1. Try WebSocket binary transfer if file_id is available
      if (fileId != null && fileId.isNotEmpty) {
        final wsResult = await _tryWebSocketDownload(fileId);
        if (wsResult != null) {
          relativePath = wsResult.relativePath;
        }
      }

      // 2. Fall back to HTTP if WebSocket unavailable
      if (relativePath == null && url != null && url.isNotEmpty) {
        final httpResult = await FileDownloadService().downloadAndSave(
          url,
          fileName: widget.message.metadata?['name'] as String?,
          mimeType: widget.message.metadata?['type'] as String?,
          expectedSize: (widget.message.metadata?['size'] as num?)?.toInt(),
          onProgress: (received, total) {
            if (mounted && total != null && total > 0) {
              setState(() {
                _progress = received / total;
              });
            }
          },
        );
        relativePath = httpResult.relativePath;
      }

      if (relativePath == null) {
        throw Exception('No download method available');
      }

      if (!mounted) return;

      // Update message metadata in DB
      final existingMeta =
          Map<String, dynamic>.from(widget.message.metadata ?? {});
      existingMeta['path'] = relativePath;
      existingMeta['download_status'] = 'completed';

      await LocalDatabaseService().updateMessage(
        messageId: widget.message.id,
        content: widget.message.content,
        metadata: existingMeta,
      );

      // Also update in-memory metadata so subsequent taps work immediately
      widget.message.metadata?['path'] = relativePath;
      widget.message.metadata?['download_status'] = 'completed';

      // Load the downloaded file
      final fullPath =
          await LocalFileStorageService().getFullPath(relativePath);
      final file = File(fullPath);

      if (mounted) {
        setState(() {
          _downloadStatus = 'completed';
          _imageFile = file;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadStatus = 'pending';
          _progress = 0.0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }

  Future<WsFileDownloadResult?> _tryWebSocketDownload(String fileId) async {
    final agentId = widget.message.from.id;

    // Try client connection (app connected TO agent) — reuse existing or reconnect
    try {
      ACPAgentConnection? connection = ChatService().getACPConnection(agentId);
      bool temporaryConnection = false;

      // If no live connection, look up the agent and create a temporary one
      if (connection == null) {
        final agent = await LocalDatabaseService().getRemoteAgentById(agentId);
        if (agent != null && agent.endpoint.isNotEmpty && agent.protocol == ProtocolType.acp) {
          String wsUrl = agent.endpoint;
          if (!wsUrl.startsWith('ws://') && !wsUrl.startsWith('wss://')) {
            wsUrl = wsUrl
                .replaceFirst('https://', 'wss://')
                .replaceFirst('http://', 'ws://');
          }
          if (!wsUrl.contains('/acp/ws')) {
            wsUrl = wsUrl.endsWith('/') ? '${wsUrl}acp/ws' : '$wsUrl/acp/ws';
          }
          final tempConn = ACPAgentConnection(
            agentId: agentId,
            autoReconnect: false,
          );
          try {
            await tempConn.connect(
              wsUrl,
              agent.token,
              targetAgentId: agent.metadata['target_agent_id'] as String?,
              pinnedFingerprint:
                  (agent.metadata['noise_peer_fp'] as String?) ?? '',
              cachedPeerStaticPublicKey: decodeCachedPeerPublicKey(
                agent.metadata['cached_peer_static_public_key'],
              ),
            );
            connection = tempConn;
            temporaryConnection = true;
          } catch (e) {
            LoggerService().warning(
              'WS reconnect for file download failed: $e',
              tag: 'ImageMessage',
            );
          }
        }
      }

      if (connection != null) {
        try {
          return await WsFileTransferService().downloadViaClientConnection(
            connection: connection,
            fileId: fileId,
            onProgress: (received, total) {
              if (mounted && total != null && total > 0) {
                setState(() {
                  _progress = received / total;
                });
              }
            },
          );
        } finally {
          if (temporaryConnection) {
            await connection.disconnect();
          }
        }
      }
    } catch (e) {
      LoggerService().error('WS client download failed', tag: 'ImageMessage', error: e);
    }

    // Try server connection (agent connected TO app)
    try {
      final acp = acpServerOrNull;
      if (acp != null && acp.isRunning) {
        return await WsFileTransferService().downloadViaServerConnection(
          server: acp,
          agentId: agentId,
          fileId: fileId,
          onProgress: (received, total) {
            if (mounted && total != null && total > 0) {
              setState(() {
                _progress = received / total;
              });
            }
          },
        );
      }
    } catch (e) {
      LoggerService().error('WS server download failed', tag: 'ImageMessage', error: e);
    }

    return null;
  }

  Future<void> _openViewer() async {
    if (_imageFile == null) return;

    // Build gallery items from all image messages
    final galleryItems = <ImageGalleryItem>[];
    final storageService = LocalFileStorageService();

    if (widget.allImageMessages.isNotEmpty) {
      for (final msg in widget.allImageMessages) {
        final path = msg.metadata?['path'] as String?;
        if (path == null) continue;
        try {
          final fullPath = await storageService.getFullPath(path);
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

    // Fallback: if gallery building failed, show single image
    if (galleryItems.isEmpty) {
      galleryItems.add(ImageGalleryItem(
        file: _imageFile!,
        title: widget.message.metadata?['name'] as String?,
      ));
    }

    // Determine actual index (may differ if some images failed to load)
    int actualIndex = widget.imageIndex.clamp(0, galleryItems.length - 1);

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

  Widget _buildThumbnailOrPlaceholder() {
    if (_thumbnailBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 220,
            maxHeight: 220,
          ),
          child: Image.memory(
            _thumbnailBytes!,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _buildPlaceholder();
            },
          ),
        ),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      width: 180,
      height: 120,
      decoration: BoxDecoration(
        color: Colors.grey[300],
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Center(
        child: Icon(Icons.image, color: Colors.grey, size: 40),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // State: completed with image file loaded
    if (_downloadStatus == 'completed' && _imageFile != null) {
      return GestureDetector(
        onTap: _openViewer,
        child: Hero(
          tag: 'chat_image_${widget.imageIndex}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 220,
                maxHeight: 220,
              ),
              child: Image.file(
                _imageFile!,
                fit: BoxFit.cover,
                cacheWidth: 440,
                cacheHeight: 440,
                errorBuilder: (context, error, stackTrace) {
                  return const SizedBox(
                    width: 180,
                    height: 80,
                    child: Center(
                      child: Icon(Icons.broken_image, color: Colors.grey),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    // State: completed but file not loaded yet (loading from disk)
    if (_downloadStatus == 'completed' && _imageFile == null) {
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

    // State: downloading — thumbnail/placeholder + progress indicator
    if (_downloadStatus == 'downloading') {
      return Stack(
        alignment: Alignment.center,
        children: [
          _buildThumbnailOrPlaceholder(),
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: CircularProgressIndicator(
                value: _progress > 0 ? _progress : null,
                strokeWidth: 3,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          ),
        ],
      );
    }

    // State: pending — thumbnail/placeholder + download icon overlay
    return GestureDetector(
      onTap: _startDownload,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _buildThumbnailOrPlaceholder(),
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.download_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }
}
