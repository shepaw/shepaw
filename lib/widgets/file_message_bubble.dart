import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import '../models/message.dart';
import '../models/remote_agent.dart';
import '../services/logger_service.dart';
import '../services/local_file_storage_service.dart';
import '../services/local_database_service.dart';
import '../services/file_download_service.dart';
import '../services/attachment_service.dart';
import '../services/ws_file_transfer_service.dart';
import '../services/acp_agent_connection.dart';
import '../services/chat_service.dart';
import '../services/peer_key_utils.dart';
import '../service_locator.dart' show acpServerOrNull;

/// Displays file messages as a card component showing icon, name, and size.
/// Supports three download states:
/// - **pending**: shows file card with a download button
/// - **downloading**: shows file card with a progress indicator
/// - **completed**: tap opens the file with the system's default app
class FileMessageBubble extends StatefulWidget {
  final Message message;
  final bool isMyMessage;

  const FileMessageBubble({
    Key? key,
    required this.message,
    required this.isMyMessage,
  }) : super(key: key);

  @override
  State<FileMessageBubble> createState() => _FileMessageBubbleState();
}

class _FileMessageBubbleState extends State<FileMessageBubble> {
  /// One of 'pending', 'downloading', 'completed'.
  String _downloadStatus = 'completed';
  double _progress = 0.0;
  /// Cached path after download, so we don't rely on widget.message.metadata.
  String? _downloadedPath;

  @override
  void initState() {
    super.initState();
    // Default to 'completed' for backward compat with existing messages
    _downloadStatus =
        widget.message.metadata?['download_status'] as String? ?? 'completed';
  }

  String get _fileName =>
      widget.message.metadata?['name'] as String? ?? 'Unknown file';

  int get _fileSize => (widget.message.metadata?['size'] as num?)?.toInt() ?? 0;

  String get _fileType => widget.message.metadata?['type'] as String? ?? 'file';

  IconData get _fileIcon {
    switch (_fileType) {
      case 'document':
        return Icons.description;
      case 'video':
        return Icons.videocam;
      case 'audio':
        return Icons.audiotrack;
      default:
        final ext = _fileName.split('.').last.toLowerCase();
        switch (ext) {
          case 'pdf':
            return Icons.picture_as_pdf;
          case 'doc':
          case 'docx':
            return Icons.article;
          case 'xls':
          case 'xlsx':
            return Icons.table_chart;
          case 'ppt':
          case 'pptx':
            return Icons.slideshow;
          case 'zip':
          case 'rar':
          case '7z':
          case 'tar':
          case 'gz':
            return Icons.folder_zip;
          case 'txt':
          case 'md':
            return Icons.text_snippet;
          default:
            return Icons.insert_drive_file;
        }
    }
  }

  Color get _iconColor {
    final ext = _fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Colors.red;
      case 'doc':
      case 'docx':
        return Colors.blue;
      case 'xls':
      case 'xlsx':
        return Colors.green;
      case 'ppt':
      case 'pptx':
        return Colors.orange;
      case 'zip':
      case 'rar':
      case '7z':
        return Colors.amber[700]!;
      default:
        return Colors.blueGrey;
    }
  }

  Future<void> _openFile() async {
    final relativePath =
        _downloadedPath ?? widget.message.metadata?['path'] as String?;
    if (relativePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File path not found')),
        );
      }
      return;
    }

    try {
      final fullPath =
          await LocalFileStorageService().getFullPath(relativePath);
      await OpenFile.open(fullPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot open file: $e')),
        );
      }
    }
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
          expectedSize: widget.message.metadata?['size'] as int?,
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

      if (mounted) {
        setState(() {
          _downloadStatus = 'completed';
          _downloadedPath = relativePath;
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
              tag: 'FileMessage',
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
      LoggerService().error('WS client download failed', tag: 'FileMessage', error: e);
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
      LoggerService().error('WS server download failed', tag: 'FileMessage', error: e);
    }

    return null;
  }

  void _handleTap() {
    if (_downloadStatus == 'completed') {
      _openFile();
    } else if (_downloadStatus == 'pending') {
      _startDownload();
    }
    // downloading → no-op
  }

  Widget _buildTrailingWidget() {
    if (_downloadStatus == 'pending') {
      return Icon(
        Icons.download_rounded,
        color: widget.isMyMessage ? Colors.white70 : Colors.blueGrey,
        size: 22,
      );
    }
    if (_downloadStatus == 'downloading') {
      return SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          value: _progress > 0 ? _progress : null,
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(
            widget.isMyMessage ? Colors.white70 : Colors.blueGrey,
          ),
        ),
      );
    }
    // completed — no trailing icon
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.isMyMessage
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.05);
    final textColor = widget.isMyMessage ? Colors.white : Colors.black87;
    final subtitleColor = widget.isMyMessage ? Colors.white70 : Colors.black54;

    return GestureDetector(
      onTap: _handleTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_fileIcon, color: _iconColor, size: 22),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _fileName,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    AttachmentService.formatFileSize(_fileSize),
                    style: TextStyle(
                      color: subtitleColor,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _buildTrailingWidget(),
          ],
        ),
      ),
    );
  }
}
