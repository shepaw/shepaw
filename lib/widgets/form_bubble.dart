import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'file_upload_bubble.dart';

/// Widget that renders a composite form inline in a message bubble.
///
/// Supports mixing multiple field types in a single form:
/// - text_input: free-text input field
/// - single_select: radio-style selection
/// - multi_select: checkbox-style selection
/// - file_upload: file picker
/// - action_buttons: action buttons (within form context)
///
/// All fields are collected and submitted together as a single form response.
class FormBubble extends StatefulWidget {
  final Map<String, dynamic> formData;
  final void Function(String formId, Map<String, dynamic> values, String summary)? onFormSubmitted;

  const FormBubble({
    Key? key,
    required this.formData,
    this.onFormSubmitted,
  }) : super(key: key);

  @override
  State<FormBubble> createState() => _FormBubbleState();
}

class _FormBubbleState extends State<FormBubble> {
  final Map<String, dynamic> _fieldValues = {};
  final Map<String, TextEditingController> _textControllers = {};

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.formData['title'] as String?;
    final description = widget.formData['description'] as String?;
    final formId = widget.formData['form_id'] as String? ?? '';
    final fields = (widget.formData['fields'] as List<dynamic>?) ?? [];
    final submittedValues = widget.formData['submitted_values'] as Map<String, dynamic>?;
    final isSubmitted = submittedValues != null;

    if (fields.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Form header
        if (title != null && title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4, top: 4),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                color: Colors.black87,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (description != null && description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              description,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.black54,
              ),
            ),
          ),

        // Divider after header
        if (title != null || description != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Divider(height: 1, color: Colors.grey[300]),
          ),

        // Form fields
        ...fields.asMap().entries.map((entry) {
          final index = entry.key;
          final field = entry.value as Map<String, dynamic>;
          return Padding(
            padding: EdgeInsets.only(bottom: index < fields.length - 1 ? 12 : 0),
            child: isSubmitted
                ? _buildSubmittedField(context, field, submittedValues)
                : _buildField(context, field),
          );
        }),

        // Submit button
        if (!isSubmitted) ...[
          const SizedBox(height: 12),
          _buildFormSubmitButton(context, formId, fields),
        ] else ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.check_circle, size: 16, color: Theme.of(context).primaryColor),
              const SizedBox(width: 6),
              Text(
                AppLocalizations.of(context).widget_formSubmitted,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).primaryColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildField(BuildContext context, Map<String, dynamic> field) {
    final type = field['type'] as String? ?? 'text_input';
    final label = field['label'] as String?;
    final fieldId = field['field_id'] as String? ?? '';
    final required = field['required'] as bool? ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null && label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (required)
                  const Text(
                    ' *',
                    style: TextStyle(fontSize: 13, color: Colors.red, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
        _buildFieldInput(context, type, field, fieldId),
      ],
    );
  }

  Widget _buildFieldInput(BuildContext context, String type, Map<String, dynamic> field, String fieldId) {
    switch (type) {
      case 'text_input':
        return _buildTextInput(context, field, fieldId);
      case 'single_select':
        return _buildSingleSelect(context, field, fieldId);
      case 'multi_select':
        return _buildMultiSelect(context, field, fieldId);
      case 'file_upload':
        return _buildFileUpload(context, field, fieldId);
      default:
        return Text('Unknown field type: $type',
            style: TextStyle(fontSize: 12, color: Colors.grey[500]));
    }
  }

  Widget _buildTextInput(BuildContext context, Map<String, dynamic> field, String fieldId) {
    final placeholder = field['placeholder'] as String? ?? '';
    final maxLines = field['max_lines'] as int? ?? 1;

    _textControllers.putIfAbsent(fieldId, () {
      final controller = TextEditingController(text: _fieldValues[fieldId] as String? ?? '');
      controller.addListener(() {
        _fieldValues[fieldId] = controller.text;
      });
      return controller;
    });

    return TextField(
      controller: _textControllers[fieldId],
      maxLines: maxLines,
      decoration: InputDecoration(
        hintText: placeholder,
        hintStyle: TextStyle(fontSize: 13, color: Colors.grey[400]),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Theme.of(context).primaryColor, width: 1.5),
        ),
      ),
      style: const TextStyle(fontSize: 14),
    );
  }

  Widget _buildSingleSelect(BuildContext context, Map<String, dynamic> field, String fieldId) {
    final options = (field['options'] as List<dynamic>?) ?? [];
    final selectedId = _fieldValues[fieldId] as String?;

    return Column(
      children: options.map<Widget>((option) {
        final optionMap = option as Map<String, dynamic>;
        final id = optionMap['id'] as String? ?? '';
        final label = optionMap['label'] as String? ?? '';
        final isSelected = selectedId == id;

        return GestureDetector(
          onTap: () {
            setState(() {
              _fieldValues[fieldId] = id;
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(context).primaryColor.withOpacity(0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected
                    ? Theme.of(context).primaryColor.withOpacity(0.3)
                    : Colors.grey[300]!,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 20,
                  color: isSelected ? Theme.of(context).primaryColor : Colors.grey[400],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.black87,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMultiSelect(BuildContext context, Map<String, dynamic> field, String fieldId) {
    final options = (field['options'] as List<dynamic>?) ?? [];
    final selectedIds = (_fieldValues[fieldId] as List<String>?) ?? [];

    return Column(
      children: options.map<Widget>((option) {
        final optionMap = option as Map<String, dynamic>;
        final id = optionMap['id'] as String? ?? '';
        final label = optionMap['label'] as String? ?? '';
        final isSelected = selectedIds.contains(id);

        return GestureDetector(
          onTap: () {
            setState(() {
              final current = List<String>.from(selectedIds);
              if (current.contains(id)) {
                current.remove(id);
              } else {
                current.add(id);
              }
              _fieldValues[fieldId] = current;
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(context).primaryColor.withOpacity(0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected
                    ? Theme.of(context).primaryColor.withOpacity(0.3)
                    : Colors.grey[300]!,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 20,
                  color: isSelected ? Theme.of(context).primaryColor : Colors.grey[400],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.black87,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildFileUpload(BuildContext context, Map<String, dynamic> field, String fieldId) {
    final uploadData = Map<String, dynamic>.from(field);
    uploadData['upload_id'] = fieldId;
    // If files were already picked for this field, show as submitted
    final pickedFiles = _fieldValues[fieldId] as List<Map<String, dynamic>>?;

    if (pickedFiles != null && pickedFiles.isNotEmpty) {
      // Show picked files with remove option
      return Column(
        children: [
          ...pickedFiles.asMap().entries.map((entry) {
            final f = entry.value;
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).primaryColor.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file, size: 18, color: Theme.of(context).primaryColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      f['name'] as String? ?? 'File',
                      style: const TextStyle(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        final current = List<Map<String, dynamic>>.from(pickedFiles);
                        current.removeAt(entry.key);
                        _fieldValues[fieldId] = current.isEmpty ? null : current;
                      });
                    },
                    child: Icon(Icons.close, size: 16, color: Colors.grey[400]),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 4),
          _buildAddFileButton(context, field, fieldId),
        ],
      );
    }

    return FileUploadBubble(
      uploadData: uploadData,
      onUploadSubmitted: (uploadId, files, summary) {
        setState(() {
          _fieldValues[fieldId] = files;
        });
      },
    );
  }

  Widget _buildAddFileButton(BuildContext context, Map<String, dynamic> field, String fieldId) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () {
          // Reset to show the upload picker again
          setState(() {
            _fieldValues[fieldId] = null;
          });
        },
        icon: Icon(Icons.add, size: 16, color: Theme.of(context).primaryColor),
        label: Text(
          AppLocalizations.of(context).widget_changeFiles,
          style: TextStyle(fontSize: 12, color: Theme.of(context).primaryColor),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _buildSubmittedField(
    BuildContext context,
    Map<String, dynamic> field,
    Map<String, dynamic> submittedValues,
  ) {
    final type = field['type'] as String? ?? 'text_input';
    final label = field['label'] as String?;
    final fieldId = field['field_id'] as String? ?? '';
    final value = submittedValues[fieldId];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null && label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        _buildSubmittedValue(context, type, field, value),
      ],
    );
  }

  Widget _buildSubmittedValue(
    BuildContext context,
    String type,
    Map<String, dynamic> field,
    dynamic value,
  ) {
    switch (type) {
      case 'text_input':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey[200]!),
          ),
          child: Text(
            (value as String?) ?? '-',
            style: const TextStyle(fontSize: 14, color: Colors.black87),
          ),
        );

      case 'single_select':
        final options = (field['options'] as List<dynamic>?) ?? [];
        final selectedOption = options.firstWhere(
          (o) => (o as Map<String, dynamic>)['id'] == value,
          orElse: () => <String, dynamic>{},
        ) as Map<String, dynamic>;
        final selectedLabel = selectedOption['label'] as String? ?? '-';
        return Row(
          children: [
            Icon(Icons.check_circle, size: 16, color: Theme.of(context).primaryColor),
            const SizedBox(width: 6),
            Text(selectedLabel, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          ],
        );

      case 'multi_select':
        final options = (field['options'] as List<dynamic>?) ?? [];
        final selectedIds = (value as List<dynamic>?)?.cast<String>() ?? [];
        final selectedLabels = options
            .where((o) => selectedIds.contains((o as Map<String, dynamic>)['id']))
            .map((o) => (o as Map<String, dynamic>)['label'] as String? ?? '')
            .toList();
        return Wrap(
          spacing: 6,
          runSpacing: 4,
          children: selectedLabels.map((label) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: Theme.of(context).primaryColor, fontWeight: FontWeight.w500),
              ),
            );
          }).toList(),
        );

      case 'file_upload':
        final files = (value as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
        return Column(
          children: files.map<Widget>((f) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Icon(Icons.attach_file, size: 14, color: Theme.of(context).primaryColor),
                  const SizedBox(width: 4),
                  Text(
                    f['name'] as String? ?? 'File',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            );
          }).toList(),
        );

      default:
        return Text('$value', style: const TextStyle(fontSize: 14));
    }
  }

  Widget _buildFormSubmitButton(BuildContext context, String formId, List<dynamic> fields) {
    // Check if all required fields have values
    bool allRequiredFilled = true;
    for (final field in fields) {
      final fieldMap = field as Map<String, dynamic>;
      final required = fieldMap['required'] as bool? ?? false;
      final fieldId = fieldMap['field_id'] as String? ?? '';
      if (required) {
        final value = _fieldValues[fieldId];
        if (value == null || (value is String && value.trim().isEmpty) || (value is List && value.isEmpty)) {
          allRequiredFilled = false;
          break;
        }
      }
    }

    return Align(
      alignment: Alignment.centerRight,
      child: ElevatedButton.icon(
        onPressed: allRequiredFilled
            ? () {
                // Collect all field values
                final values = <String, dynamic>{};
                final summaryParts = <String>[];

                for (final field in fields) {
                  final fieldMap = field as Map<String, dynamic>;
                  final fieldId = fieldMap['field_id'] as String? ?? '';
                  final label = fieldMap['label'] as String? ?? fieldId;
                  final type = fieldMap['type'] as String? ?? 'text_input';
                  final value = _fieldValues[fieldId];

                  if (value != null) {
                    values[fieldId] = value;

                    // Build summary
                    switch (type) {
                      case 'text_input':
                        if ((value as String).isNotEmpty) {
                          summaryParts.add('$label: $value');
                        }
                        break;
                      case 'single_select':
                        final options = (fieldMap['options'] as List<dynamic>?) ?? [];
                        final opt = options.firstWhere(
                          (o) => (o as Map<String, dynamic>)['id'] == value,
                          orElse: () => <String, dynamic>{},
                        ) as Map<String, dynamic>;
                        summaryParts.add('$label: ${opt['label'] ?? value}');
                        break;
                      case 'multi_select':
                        final ids = (value as List<String>);
                        summaryParts.add('$label: ${ids.length} selected');
                        break;
                      case 'file_upload':
                        final files = (value as List<Map<String, dynamic>>);
                        summaryParts.add('$label: ${files.length} file(s)');
                        break;
                    }
                  }
                }

                final summary = summaryParts.join('; ');
                widget.onFormSubmitted?.call(formId, values, summary);
              }
            : null,
        icon: const Icon(Icons.send, size: 16),
        label: Text(AppLocalizations.of(context).widget_submit),
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
}
