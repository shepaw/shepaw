import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import '../services/logger_service.dart';

/// Widget that renders a file upload request inline in a message bubble.
///
/// Displays a prompt and a drop-zone style area for selecting files.
/// User can pick files, review them, remove individual files, then submit.
/// After submission, uploaded files are shown as a summary and further
/// changes are disabled.
class FileUploadBubble extends StatefulWidget {
  final Map<String, dynamic> uploadData;
  final void Function(String uploadId, List<Map<String, dynamic>> files, String summary)? onUploadSubmitted;

  const FileUploadBubble({
    Key? key,
    required this.uploadData,
    this.onUploadSubmitted,
  }) : super(key: key);

  @override
  State<FileUploadBubble> createState() => _FileUploadBubbleState();
}

class _FileUploadBubbleState extends State<FileUploadBubble> {
  final List<_PickedFileInfo> _pickedFiles = [];
  bool _isPickingFile = false;

  @override
  Widget build(BuildContext context) {
    final prompt = widget.uploadData['prompt'] as String?;
    final uploadId = widget.uploadData['upload_id'] as String? ?? '';
    final acceptTypes = (widget.uploadData['accept_types'] as List<dynamic>?)
        ?.cast<String>() ?? [];
    final maxFiles = widget.uploadData['max_files'] as int? ?? 10;
    final maxSizeMb = widget.uploadData['max_size_mb'] as int? ?? 50;
    final submittedFiles = widget.uploadData['uploaded_files'] as List<dynamic>?;
    final isSubmitted = submittedFiles != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (prompt != null && prompt.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Text(
              prompt,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.black54,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

        if (isSubmitted)
          _buildSubmittedView(submittedFiles)
        else ...[
          // Drop zone / pick area
          _buildPickArea(context, acceptTypes, maxFiles, maxSizeMb),

          // Picked file list
          if (_pickedFiles.isNotEmpty) ...[
            const SizedBox(height: 8),
            ..._pickedFiles.asMap().entries.map((entry) {
              return _buildFileRow(context, entry.key, entry.value);
            }),
          ],

          // Constraints hint
          _buildConstraintsHint(acceptTypes, maxFiles, maxSizeMb),

          // Submit button
          const SizedBox(height: 8),
          _buildSubmitButton(context, uploadId),
        ],
      ],
    );
  }

  Widget _buildPickArea(BuildContext context, List<String> acceptTypes, int maxFiles, int maxSizeMb) {
    final canAddMore = _pickedFiles.length < maxFiles;

    return GestureDetector(
      onTap: canAddMore && !_isPickingFile ? () => _pickFiles(acceptTypes, maxFiles, maxSizeMb) : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: BoxDecoration(
          color: canAddMore ? Colors.grey[50] : Colors.grey[100],
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: canAddMore ? Theme.of(context).primaryColor.withOpacity(0.3) : Colors.grey[300]!,
            width: 1.5,
            style: BorderStyle.solid,
          ),
        ),
        child: Column(
          children: [
            Icon(
              Icons.cloud_upload_outlined,
              size: 32,
              color: canAddMore ? Theme.of(context).primaryColor : Colors.grey[400],
            ),
            const SizedBox(height: 6),
            Text(
              canAddMore
                  ? (_pickedFiles.isEmpty ? 'Tap to select files' : 'Tap to add more files')
                  : 'Maximum files reached',
              style: TextStyle(
                fontSize: 13,
                color: canAddMore ? Theme.of(context).primaryColor : Colors.grey[500],
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileRow(BuildContext context, int index, _PickedFileInfo fileInfo) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!, width: 1),
      ),
      child: Row(
        children: [
          Icon(
            _getFileIcon(fileInfo.extension),
            size: 20,
            color: Theme.of(context).primaryColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileInfo.name,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _formatFileSize(fileInfo.sizeBytes),
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() {
                _pickedFiles.removeAt(index);
              });
            },
            child: Icon(Icons.close, size: 18, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildConstraintsHint(List<String> acceptTypes, int maxFiles, int maxSizeMb) {
    final parts = <String>[];
    if (acceptTypes.isNotEmpty) {
      parts.add('Accepted: ${acceptTypes.join(', ')}');
    }
    parts.add('Max $maxFiles file${maxFiles > 1 ? 's' : ''}, ${maxSizeMb}MB each');

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        parts.join(' · '),
        style: TextStyle(fontSize: 11, color: Colors.grey[400]),
      ),
    );
  }

  Widget _buildSubmittedView(List<dynamic> files) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...files.map<Widget>((f) {
          final fileMap = f as Map<String, dynamic>;
          final name = fileMap['name'] as String? ?? 'File';
          final size = fileMap['size'] as int? ?? 0;
          final ext = path.extension(name).replaceAll('.', '');
          return Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).primaryColor.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _getFileIcon(ext),
                  size: 20,
                  color: Theme.of(context).primaryColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _formatFileSize(size),
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
                const SizedBox(width: 6),
                Icon(Icons.check_circle, size: 16, color: Theme.of(context).primaryColor),
              ],
            ),
          );
        }),
        const SizedBox(height: 4),
        Text(
          '${files.length} file${files.length > 1 ? 's' : ''} uploaded',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).primaryColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildSubmitButton(BuildContext context, String uploadId) {
    final hasFiles = _pickedFiles.isNotEmpty;

    return Align(
      alignment: Alignment.centerRight,
      child: ElevatedButton.icon(
        onPressed: hasFiles
            ? () {
                final fileDataList = _pickedFiles.map((f) => {
                  'name': f.name,
                  'path': f.path,
                  'size': f.sizeBytes,
                  'type': f.mimeType,
                }).toList();
                final summary = _pickedFiles.map((f) => f.name).join(', ');
                widget.onUploadSubmitted?.call(uploadId, fileDataList, summary);
              }
            : null,
        icon: const Icon(Icons.upload, size: 16),
        label: Text(hasFiles ? 'Upload (${_pickedFiles.length})' : 'Upload'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).primaryColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey[300],
          disabledForegroundColor: Colors.grey[500],
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Future<void> _pickFiles(List<String> acceptTypes, int maxFiles, int maxSizeMb) async {
    if (_isPickingFile) return;

    setState(() {
      _isPickingFile = true;
    });

    try {
      final remaining = maxFiles - _pickedFiles.length;
      if (remaining <= 0) return;

      // Map accept types to FileType
      FileType fileType = FileType.any;
      List<String>? allowedExtensions;
      if (acceptTypes.isNotEmpty) {
        // Check if all types are images
        final allImages = acceptTypes.every((t) =>
            ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg'].contains(t.toLowerCase()));
        if (allImages) {
          fileType = FileType.image;
        } else {
          fileType = FileType.custom;
          allowedExtensions = acceptTypes;
        }
      }

      FilePickerResult? result;
      if (fileType == FileType.custom && allowedExtensions != null) {
        result = await FilePicker.platform.pickFiles(
          type: fileType,
          allowedExtensions: allowedExtensions,
          allowMultiple: remaining > 1,
        );
      } else {
        result = await FilePicker.platform.pickFiles(
          type: fileType,
          allowMultiple: remaining > 1,
        );
      }

      if (result == null || result.files.isEmpty) return;

      final maxSizeBytes = maxSizeMb * 1024 * 1024;
      final newFiles = <_PickedFileInfo>[];

      for (final file in result.files) {
        if (file.path == null) continue;
        if (file.size > maxSizeBytes) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${file.name} exceeds ${maxSizeMb}MB limit'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          continue;
        }
        if (_pickedFiles.length + newFiles.length >= maxFiles) break;

        newFiles.add(_PickedFileInfo(
          name: file.name,
          path: file.path!,
          sizeBytes: file.size,
          extension: file.extension ?? '',
          mimeType: _getMimeType(file.extension ?? ''),
        ));
      }

      if (newFiles.isNotEmpty) {
        setState(() {
          _pickedFiles.addAll(newFiles);
        });
      }
    } catch (e) {
      LoggerService().error('Error picking files', tag: 'FileUpload', error: e);
    } finally {
      if (mounted) {
        setState(() {
          _isPickingFile = false;
        });
      }
    }
  }

  IconData _getFileIcon(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
      case 'svg':
        return Icons.image;
      case 'mp4':
      case 'mov':
      case 'avi':
        return Icons.videocam;
      case 'mp3':
      case 'wav':
      case 'm4a':
        return Icons.audiotrack;
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

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _getMimeType(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      default:
        return 'application/octet-stream';
    }
  }
}

class _PickedFileInfo {
  final String name;
  final String path;
  final int sizeBytes;
  final String extension;
  final String mimeType;

  _PickedFileInfo({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.extension,
    required this.mimeType,
  });
}
