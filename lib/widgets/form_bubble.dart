import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'file_upload_bubble.dart';

/// Widget that renders a composite form inline in a message bubble.
///
/// Supports mixing multiple field types in a single form:
/// - text_input / text / textarea: free-text input field
/// - select / dropdown: dropdown, pick one
/// - radio / single_select / radio_group: radio list, pick one
/// - checkbox (no options): a single yes/no box
/// - checkbox (with options) / multi_select / checkbox_group: checkbox list
/// - file_upload: file picker
///
/// The widget is lenient about field/option shape so it can render both
/// the legacy Shepaw wire format (`field_id`, option `id`) and the newer
/// form format emitted by non-blocking agents (`name`, option `value`).
/// `default` / `value` pre-fills a control and counts toward required.
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
  void initState() {
    super.initState();
    _seedDefaults(widget.formData);
  }

  @override
  void didUpdateWidget(FormBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.formData, widget.formData)) {
      _seedDefaults(widget.formData);
    }
  }

  /// The stable per-field key used for storing the user's input.
  ///
  /// Accepts both the legacy `field_id` and the newer `name` / `id` keys so
  /// the widget renders forms emitted by either variant of the agent SDK.
  static String _fieldKey(Map<String, dynamic> field) {
    for (final key in const ['field_id', 'name', 'id', 'key']) {
      final text = _asString(field[key]);
      if (text != null && text.isNotEmpty) return text;
    }
    return '';
  }

  static String _rawType(Map<String, dynamic> field) {
    return (_asString(field['type']) ?? 'text_input').trim().toLowerCase();
  }

  /// Canonicalise [type] into a kind this widget knows how to render.
  ///
  /// A bare `checkbox` is a yes/no box; the same type with `options` is a
  /// checkbox group. Unknown types are returned as-is so the fallback still
  /// shows "Unknown field type".
  static String _fieldKind(Map<String, dynamic> field) {
    final type = _rawType(field);
    if (type == 'checkbox' || type == 'check') {
      final options = field['options'];
      if (options is List && options.isNotEmpty) return 'multi_select';
      return 'checkbox';
    }
    switch (type) {
      case 'radio':
      case 'radio_group':
      case 'single_select':
      case 'singleselect':
        return 'single_select';
      case 'select':
      case 'dropdown':
      case 'enum':
        return 'select';
      case 'checkbox_group':
      case 'checkboxes':
      case 'multi_select':
      case 'multiselect':
      case 'multi-select':
        return 'multi_select';
      case 'switch':
      case 'toggle':
      case 'boolean':
      case 'bool':
        return 'checkbox';
      case 'textarea':
      case 'multiline':
        return 'textarea';
      case 'text':
      case 'text_input':
      case 'input':
      case 'string':
      case 'number':
      case 'integer':
      case 'email':
      case 'password':
      case 'url':
      case 'tel':
      case 'phone':
        return 'text_input';
      default:
        return type;
    }
  }

  static bool _isRequired(Map<String, dynamic> field) {
    final raw = field['required'];
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final text = _asString(raw)?.trim().toLowerCase();
    return text == 'true' || text == '1' || text == 'yes' || text == 'required';
  }

  static String? _asString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return '$value';
  }

  static bool _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = _asString(value)?.trim().toLowerCase();
    return text == 'true' || text == '1' || text == 'yes' || text == 'on';
  }

  static List<String> _asStringList(dynamic value) {
    if (value is List) {
      return value
          .map(_asString)
          .whereType<String>()
          .where((item) => item.isNotEmpty)
          .toList();
    }
    final one = _asString(value);
    if (one == null || one.isEmpty) return <String>[];
    return [one];
  }

  static bool _isBlank(dynamic value) {
    if (value == null) return true;
    if (value is String) return value.trim().isEmpty;
    if (value is List) return value.isEmpty;
    return false;
  }

  /// The stable per-option key; accepts both the legacy `id` and the
  /// newer `value` shapes, including non-string ids.
  static String _optionKey(Map<String, dynamic> option) {
    for (final key in const ['id', 'value', 'name']) {
      final text = _asString(option[key]);
      if (text != null && text.isNotEmpty) return text;
    }
    return '';
  }

  static String _optionLabel(Map<String, dynamic> option, String fallback) {
    for (final key in const ['label', 'text', 'name']) {
      final text = _asString(option[key]);
      if (text != null && text.isNotEmpty) return text;
    }
    return fallback;
  }

  /// Options may be maps (`id`/`value` + `label`) or plain strings.
  static List<Map<String, dynamic>> _normalizeOptions(dynamic raw) {
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      final Map<String, dynamic> option;
      if (item is Map) {
        option = Map<String, dynamic>.from(item);
      } else {
        final text = _asString(item);
        if (text == null || text.isEmpty) continue;
        option = {'id': text, 'label': text};
      }
      var id = _optionKey(option);
      if (id.isEmpty) {
        id = '__idx_$i';
        option['id'] = id;
      }
      if (!seen.add(id)) continue;
      out.add(option);
    }
    return out;
  }

  static dynamic _rawInitial(Map<String, dynamic> field) {
    for (final key in const [
      'default',
      'default_value',
      'initial',
      'initial_value',
      'value',
    ]) {
      if (!field.containsKey(key)) continue;
      final raw = field[key];
      if (raw != null) return raw;
    }
    return null;
  }

  static dynamic _coerceInitial(String kind, dynamic initial) {
    switch (kind) {
      case 'checkbox':
        return _asBool(initial);
      case 'multi_select':
        return _asStringList(initial);
      case 'text_input':
      case 'textarea':
      case 'select':
      case 'single_select':
        if (initial is List) {
          return initial.isEmpty ? '' : (_asString(initial.first) ?? '');
        }
        return _asString(initial) ?? '';
      default:
        return initial;
    }
  }

  void _seedDefaults(Map<String, dynamic> formData) {
    final fields = formData['fields'];
    if (fields is! List) return;
    for (final raw in fields) {
      if (raw is! Map) continue;
      final field = Map<String, dynamic>.from(raw);
      final fieldId = _fieldKey(field);
      if (fieldId.isEmpty || _fieldValues.containsKey(fieldId)) continue;
      final initial = _rawInitial(field);
      if (initial == null) continue;
      _fieldValues[fieldId] = _coerceInitial(_fieldKind(field), initial);
    }
  }

  bool _isSatisfied(Map<String, dynamic> field) {
    if (!_isRequired(field)) return true;
    final fieldId = _fieldKey(field);
    final kind = _fieldKind(field);
    if (kind == 'text_input' || kind == 'textarea') {
      final live = _textControllers[fieldId]?.text ?? _fieldValues[fieldId];
      return live is String && live.trim().isNotEmpty;
    }
    final value = _fieldValues[fieldId];
    if (kind == 'checkbox') return value == true;
    if (value == null) return false;
    if (value is String) return value.trim().isNotEmpty;
    if (value is List) return value.isNotEmpty;
    if (value is bool) return value;
    return true;
  }

  String _selectedOptionLabel(Map<String, dynamic> field, dynamic value) {
    final key = _asString(value) ?? '';
    for (final option in _normalizeOptions(field['options'])) {
      if (_optionKey(option) == key) return _optionLabel(option, key);
    }
    return key;
  }

  List<String> _selectedIds(String fieldId) => _asStringList(_fieldValues[fieldId]);

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

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, minWidth: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Form header
              if (title != null && title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4, top: 4),
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (description != null && description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    description,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.54),
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
                  padding: EdgeInsets.only(
                      bottom: index < fields.length - 1 ? 12 : 0),
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
                    Icon(Icons.check_circle,
                        size: 16, color: Theme.of(context).primaryColor),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        AppLocalizations.of(context).widget_formSubmitted,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).primaryColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Label + optional required mark that wraps instead of overflowing a Row.
  Widget _buildFieldLabel(
    String label, {
    required bool required,
    required TextStyle style,
  }) {
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: label),
          if (required)
            const TextSpan(
              text: ' *',
              style: TextStyle(
                fontSize: 13,
                color: Colors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildField(BuildContext context, Map<String, dynamic> field) {
    final label = _asString(field['label']);
    final fieldId = _fieldKey(field);
    final required = _isRequired(field);
    final kind = _fieldKind(field);

    // A single checkbox keeps its label on the same row as the box.
    if (kind == 'checkbox') {
      return _buildCheckbox(
        context,
        field,
        fieldId,
        label: label,
        required: required,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null && label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _buildFieldLabel(
              label,
              required: required,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        _buildFieldInput(context, field, fieldId),
      ],
    );
  }

  Widget _buildFieldInput(
    BuildContext context,
    Map<String, dynamic> field,
    String fieldId,
  ) {
    switch (_fieldKind(field)) {
      case 'text_input':
      case 'textarea':
        return _buildTextInput(context, field, fieldId);
      case 'select':
        return _buildSelect(context, field, fieldId);
      case 'single_select':
        return _buildSingleSelect(context, field, fieldId);
      case 'multi_select':
        return _buildMultiSelect(context, field, fieldId);
      case 'file_upload':
        return _buildFileUpload(context, field, fieldId);
      default:
        return Text(
          'Unknown field type: ${_rawType(field)}',
          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
        );
    }
  }

  InputDecoration _fieldDecoration(BuildContext context, String hint) {
    return InputDecoration(
      hintText: hint,
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
    );
  }

  int _maxLines(Map<String, dynamic> field, String raw) {
    final specified = field['max_lines'] ?? field['rows'];
    if (specified is int && specified > 0) return specified;
    if (specified is num && specified > 0) return specified.toInt();
    if (raw == 'textarea' || raw == 'multiline') return 4;
    return 1;
  }

  TextInputType _keyboardFor(String raw) {
    switch (raw) {
      case 'number':
      case 'integer':
      case 'float':
        return TextInputType.number;
      case 'email':
        return TextInputType.emailAddress;
      case 'url':
        return TextInputType.url;
      case 'tel':
      case 'phone':
        return TextInputType.phone;
      case 'textarea':
      case 'multiline':
        return TextInputType.multiline;
      default:
        return TextInputType.text;
    }
  }

  Widget _buildTextInput(
    BuildContext context,
    Map<String, dynamic> field,
    String fieldId,
  ) {
    final raw = _rawType(field);
    final placeholder = _asString(field['placeholder']) ?? '';
    final maxLines = _maxLines(field, raw);

    _textControllers.putIfAbsent(fieldId, () {
      return TextEditingController(text: _asString(_fieldValues[fieldId]) ?? '');
    });

    return TextField(
      controller: _textControllers[fieldId],
      maxLines: maxLines,
      keyboardType: _keyboardFor(raw),
      obscureText: raw == 'password',
      onChanged: (text) {
        // 只在「空 / 非空」切换时重建。每次按键都 setState 会打断中文输入法，
        // 而提交按钮只关心必填项有没有内容。
        final previous = _fieldValues[fieldId];
        _fieldValues[fieldId] = text;
        if (_isBlank(previous) != _isBlank(text)) {
          setState(() {});
        }
      },
      decoration: _fieldDecoration(context, placeholder),
      style: const TextStyle(fontSize: 14),
    );
  }

  Widget _buildSelect(
    BuildContext context,
    Map<String, dynamic> field,
    String fieldId,
  ) {
    final options = _normalizeOptions(field['options']);
    final placeholder = _asString(field['placeholder']) ?? '';
    final selected = _asString(_fieldValues[fieldId]);
    final valid = options.map(_optionKey).toSet();
    final value = (selected != null && valid.contains(selected)) ? selected : null;

    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      hint: placeholder.isEmpty
          ? null
          : Text(
              placeholder,
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              overflow: TextOverflow.ellipsis,
            ),
      decoration: _fieldDecoration(context, ''),
      items: options.map((option) {
        final id = _optionKey(option);
        return DropdownMenuItem<String>(
          value: id,
          child: Text(
            _optionLabel(option, id),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
        );
      }).toList(),
      onChanged: (next) {
        if (next == null) return;
        setState(() => _fieldValues[fieldId] = next);
      },
    );
  }

  Widget _buildCheckbox(
    BuildContext context,
    Map<String, dynamic> field,
    String fieldId, {
    required String? label,
    required bool required,
  }) {
    final checked = _fieldValues[fieldId] == true;
    final description = _asString(field['description']) ?? _asString(field['placeholder']);
    final primary = Theme.of(context).primaryColor;

    return GestureDetector(
      onTap: () => setState(() => _fieldValues[fieldId] = !checked),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: checked ? primary.withOpacity(0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: checked ? primary.withOpacity(0.3) : Colors.grey[300]!,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                checked ? Icons.check_box : Icons.check_box_outline_blank,
                size: 20,
                color: checked ? primary : Colors.grey[400],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (label != null && label.isNotEmpty)
                    _buildFieldLabel(
                      label,
                      required: required,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: checked ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  if (description != null && description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        description,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSingleSelect(BuildContext context, Map<String, dynamic> field, String fieldId) {
    final options = _normalizeOptions(field['options']);
    final selectedId = _asString(_fieldValues[fieldId]);

    return Column(
      children: options.map<Widget>((option) {
        final id = _optionKey(option);
        final label = _optionLabel(option, id);
        final description = _asString(option['description']);
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                    size: 20,
                    color: isSelected ? Theme.of(context).primaryColor : Colors.grey[400],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label.isNotEmpty ? label : id,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      if (description != null && description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            description,
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
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
    final options = _normalizeOptions(field['options']);
    final selectedIds = _selectedIds(fieldId);

    return Column(
      children: options.map<Widget>((option) {
        final id = _optionKey(option);
        final label = _optionLabel(option, id);
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
                      color: Theme.of(context).colorScheme.onSurface,
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
    final label = _asString(field['label']);
    final fieldId = _fieldKey(field);
    final value = submittedValues[fieldId];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null && label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _buildFieldLabel(
              label,
              required: false,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        _buildSubmittedValue(context, field, value),
      ],
    );
  }

  Widget _buildSubmittedValue(
    BuildContext context,
    Map<String, dynamic> field,
    dynamic value,
  ) {
    switch (_fieldKind(field)) {
      case 'text_input':
      case 'textarea':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Text(
            _asString(value) ?? '-',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        );

      case 'single_select':
      case 'select':
        final selectedLabel = _selectedOptionLabel(field, value);
        final shown = selectedLabel.isEmpty ? '-' : selectedLabel;
        return Row(
          children: [
            Icon(Icons.check_circle, size: 16, color: Theme.of(context).primaryColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                shown,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        );

      case 'checkbox':
        final on = value == true;
        return Row(
          children: [
            Icon(
              on ? Icons.check_box : Icons.check_box_outline_blank,
              size: 16,
              color: on ? Theme.of(context).primaryColor : Colors.grey[500],
            ),
            const SizedBox(width: 6),
            Text(
              on ? 'true' : 'false',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ],
        );

      case 'multi_select':
        final options = _normalizeOptions(field['options']);
        final selectedIds = _asStringList(value);
        final selectedLabels = options
            .where((option) => selectedIds.contains(_optionKey(option)))
            .map((option) => _optionLabel(option, _optionKey(option)))
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
                  Expanded(
                    child: Text(
                      f['name'] as String? ?? 'File',
                      style: const TextStyle(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
    final allRequiredFilled = fields.every((field) {
      if (field is! Map) return true;
      return _isSatisfied(Map<String, dynamic>.from(field));
    });

    return Align(
      alignment: Alignment.centerRight,
      child: ElevatedButton.icon(
        onPressed: allRequiredFilled
            ? () {
                final values = <String, dynamic>{};
                final summaryParts = <String>[];

                for (final field in fields) {
                  if (field is! Map) continue;
                  final fieldMap = Map<String, dynamic>.from(field);
                  final fieldId = _fieldKey(fieldMap);
                  final label = _asString(fieldMap['label']) ?? fieldId;
                  final kind = _fieldKind(fieldMap);
                  final value = (kind == 'text_input' || kind == 'textarea')
                      ? (_textControllers[fieldId]?.text ?? _fieldValues[fieldId])
                      : _fieldValues[fieldId];

                  if (value == null) continue;
                  if (value is String && value.isEmpty) continue;
                  values[fieldId] = value;

                  switch (kind) {
                    case 'text_input':
                    case 'textarea':
                      final text = _asString(value) ?? '';
                      if (text.isNotEmpty) summaryParts.add('$label: $text');
                      break;
                    case 'select':
                    case 'single_select':
                      summaryParts.add('$label: ${_selectedOptionLabel(fieldMap, value)}');
                      break;
                    case 'checkbox':
                      summaryParts.add('$label: ${value == true}');
                      break;
                    case 'multi_select':
                      final ids = _asStringList(value);
                      final options = _normalizeOptions(fieldMap['options']);
                      final selectedLabels = options
                          .where((option) => ids.contains(_optionKey(option)))
                          .map((option) => _optionLabel(option, ''))
                          .where((text) => text.isNotEmpty)
                          .toList();
                      summaryParts.add(
                        selectedLabels.isEmpty
                            ? '$label: ${ids.length} selected'
                            : '$label: ${selectedLabels.join(", ")}',
                      );
                      break;
                    case 'file_upload':
                      final files = value is List ? value : const [];
                      summaryParts.add('$label: ${files.length} file(s)');
                      break;
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
