import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../form_bubble.dart';
import '../form_field_shape.dart';

/// 输入框上方停靠卡里的提问表单：一题一页，横向切换。
///
/// - 点单选项即记下答案并切到下一题；多选、文字题用「下一题」前进。
/// - 「上一题」或右滑回到前一题；题号可直接点跳转。
/// - 每题都答了（显式 `required: false` 的可空）提交按钮才点亮。
///
/// 只认单选 / 下拉 / 多选 / 文字 / 勾选几种字段；表单里有别的（如文件上传）
/// 时整张退回 [FormBubble] 的平铺渲染。
class PagedFormPanel extends StatefulWidget {
  final Map<String, dynamic> formData;
  final void Function(
          String formId, Map<String, dynamic> values, String summary)
      onFormSubmitted;
  final void Function(String formId)? onFormDeclined;

  const PagedFormPanel({
    super.key,
    required this.formData,
    required this.onFormSubmitted,
    this.onFormDeclined,
  });

  /// 这张表单能不能分页渲染。
  static bool supports(Map<String, dynamic> formData) {
    final fields = formData['fields'];
    if (fields is! List || fields.isEmpty) return false;
    return fields.every((raw) =>
        raw is Map &&
        _pagedKinds.contains(
            FormFieldShape.fieldKind(Map<String, dynamic>.from(raw))));
  }

  static const _pagedKinds = {
    'single_select',
    'select',
    'multi_select',
    'text_input',
    'textarea',
    'checkbox',
  };

  @override
  State<PagedFormPanel> createState() => _PagedFormPanelState();
}

class _PagedFormPanelState extends State<PagedFormPanel> {
  /// 点完单选项后停一下再翻页，让人看见选中了哪个。
  static const _advanceDelay = Duration(milliseconds: 220);

  final Map<String, dynamic> _values = {};
  final Map<String, TextEditingController> _textControllers = {};
  int _index = 0;
  bool _forward = true;
  int _advanceToken = 0;

  List<Map<String, dynamic>> get _fields => [
        for (final raw in (widget.formData['fields'] as List? ?? const []))
          if (raw is Map) Map<String, dynamic>.from(raw),
      ];

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      final id = FormFieldShape.fieldKey(field);
      final kind = FormFieldShape.fieldKind(field);
      final initial = FormFieldShape.rawInitial(field);
      if (id.isEmpty) continue;
      if (initial != null) {
        _values[id] = FormFieldShape.coerceInitial(kind, initial);
      } else if (kind == 'checkbox') {
        _values[id] = false;
      }
      if (kind == 'text_input' || kind == 'textarea') {
        _textControllers[id] = TextEditingController(
          text: FormFieldShape.asString(_values[id]) ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  dynamic _valueOf(Map<String, dynamic> field) {
    final id = FormFieldShape.fieldKey(field);
    final controller = _textControllers[id];
    return controller != null ? controller.text : _values[id];
  }

  /// 没有显式写 `required: false` 的题都要答；勾选题本身就有值。
  bool _answered(Map<String, dynamic> field) {
    if (field['required'] == false) return true;
    if (FormFieldShape.fieldKind(field) == 'checkbox') return true;
    return !FormFieldShape.isBlank(_valueOf(field));
  }

  void _goTo(int index) {
    final count = _fields.length;
    if (index < 0 || index >= count || index == _index) return;
    _advanceToken++;
    setState(() {
      _forward = index > _index;
      _index = index;
    });
  }

  void _pickSingle(Map<String, dynamic> field, String optionId) {
    setState(() => _values[FormFieldShape.fieldKey(field)] = optionId);
    if (_index >= _fields.length - 1) return;
    final token = ++_advanceToken;
    final from = _index;
    Future.delayed(_advanceDelay, () {
      // 期间用户又切了题，就别再自动翻。
      if (!mounted || token != _advanceToken || _index != from) return;
      _goTo(from + 1);
    });
  }

  void _toggleMulti(Map<String, dynamic> field, String optionId) {
    final id = FormFieldShape.fieldKey(field);
    final selected = FormFieldShape.asStringList(_values[id]);
    setState(() {
      if (selected.contains(optionId)) {
        selected.remove(optionId);
      } else {
        selected.add(optionId);
      }
      _values[id] = selected;
    });
  }

  void _submit() {
    final values = <String, dynamic>{};
    final summaryParts = <String>[];
    for (final field in _fields) {
      final id = FormFieldShape.fieldKey(field);
      final label = FormFieldShape.asString(field['label']) ?? id;
      final kind = FormFieldShape.fieldKind(field);
      final value = _valueOf(field);
      if (value == null || (value is String && value.isEmpty)) continue;
      values[id] = value;
      final options = FormFieldShape.normalizeOptions(field['options']);
      String optionLabel(String key) => options
          .where((option) => FormFieldShape.optionKey(option) == key)
          .map((option) => FormFieldShape.optionLabel(option, key))
          .firstWhere((_) => true, orElse: () => key);
      switch (kind) {
        case 'select':
        case 'single_select':
          summaryParts.add('$label: ${optionLabel('$value')}');
          break;
        case 'multi_select':
          final labels =
              FormFieldShape.asStringList(value).map(optionLabel).join(', ');
          summaryParts.add('$label: $labels');
          break;
        case 'checkbox':
          summaryParts.add('$label: ${value == true}');
          break;
        default:
          summaryParts.add('$label: $value');
      }
    }
    widget.onFormSubmitted(
      widget.formData['form_id']?.toString() ?? '',
      values,
      summaryParts.join('; '),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final fields = _fields;
    if (fields.isEmpty) return const SizedBox.shrink();
    final index = _index.clamp(0, fields.length - 1);
    final field = fields[index];
    final isLast = index == fields.length - 1;
    final allAnswered = fields.every(_answered);
    final deferred = widget.formData['deferred'] == true;
    final formId = widget.formData['form_id']?.toString() ?? '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (fields.length > 1) ...[
          _StepChips(
            count: fields.length,
            current: index,
            answered: [for (final f in fields) _answered(f)],
            onTap: _goTo,
          ),
          const SizedBox(height: 10),
        ],
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -250) _goTo(index + 1);
            if (velocity > 250) _goTo(index - 1);
          },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) {
              final incoming = child.key == ValueKey(index);
              final dx = (incoming == _forward) ? 1.0 : -1.0;
              return ClipRect(
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(dx * 0.25, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                ),
              );
            },
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, if (current != null) current],
            ),
            child: KeyedSubtree(
              key: ValueKey(index),
              child: _buildQuestion(context, field, isLast: isLast),
            ),
          ),
        ),
        if (deferred) ...[
          const SizedBox(height: 10),
          Text(
            l10n.widget_formDeferredHint,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            if (index > 0)
              TextButton.icon(
                onPressed: () => _goTo(index - 1),
                icon: const Icon(Icons.chevron_left, size: 18),
                label: Text(l10n.widget_formPrevQuestion),
              ),
            if (deferred && widget.onFormDeclined != null)
              TextButton(
                onPressed: () => widget.onFormDeclined!(formId),
                child: Text(
                  l10n.widget_formDecline,
                  style: TextStyle(
                    color: colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            const Spacer(),
            if (!isLast)
              TextButton(
                onPressed:
                    _answered(field) ? () => _goTo(index + 1) : null,
                child: Text(l10n.widget_formNextQuestion),
              ),
            const SizedBox(width: 4),
            ElevatedButton.icon(
              onPressed: allAnswered ? _submit : null,
              icon: const Icon(Icons.send, size: 16),
              label: Text(l10n.widget_submit),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildQuestion(
    BuildContext context,
    Map<String, dynamic> field, {
    required bool isLast,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final id = FormFieldShape.fieldKey(field);
    final kind = FormFieldShape.fieldKind(field);
    final label = FormFieldShape.asString(field['label']) ?? '';
    final description = FormFieldShape.asString(field['description']) ?? '';
    final options = FormFieldShape.normalizeOptions(field['options']);

    Widget input;
    switch (kind) {
      case 'single_select':
      case 'select':
        final selected = FormFieldShape.asString(_values[id]);
        input = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final option in options)
              _OptionTile(
                option: option,
                selected: FormFieldShape.optionKey(option) == selected,
                multi: false,
                onTap: () =>
                    _pickSingle(field, FormFieldShape.optionKey(option)),
              ),
          ],
        );
        break;
      case 'multi_select':
        final selected = FormFieldShape.asStringList(_values[id]);
        input = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final option in options)
              _OptionTile(
                option: option,
                selected: selected.contains(FormFieldShape.optionKey(option)),
                multi: true,
                onTap: () =>
                    _toggleMulti(field, FormFieldShape.optionKey(option)),
              ),
          ],
        );
        break;
      case 'checkbox':
        input = SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _values[id] == true,
          title: Text(
            FormFieldShape.asString(field['placeholder']) ?? label,
            style: const TextStyle(fontSize: 14),
          ),
          onChanged: (value) => setState(() => _values[id] = value),
        );
        break;
      default:
        input = TextField(
          controller: _textControllers[id],
          autofocus: false,
          minLines: kind == 'textarea' ? 3 : 1,
          maxLines: kind == 'textarea' ? 6 : 3,
          textInputAction:
              isLast ? TextInputAction.done : TextInputAction.next,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (!isLast && _answered(field)) _goTo(_index + 1);
          },
          decoration: InputDecoration(
            hintText: FormFieldShape.asString(field['placeholder']),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label.isNotEmpty)
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
        const SizedBox(height: 10),
        input,
      ],
    );
  }
}

/// 题号条：当前题高亮，答过的打勾，点了直接跳。
class _StepChips extends StatelessWidget {
  final int count;
  final int current;
  final List<bool> answered;
  final ValueChanged<int> onTap;

  const _StepChips({
    required this.count,
    required this.current,
    required this.answered,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onTap(i),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: i == current
                        ? colorScheme.primary
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (answered[i] && i != current) ...[
                        Icon(Icons.check, size: 12, color: colorScheme.primary),
                        const SizedBox(width: 2),
                      ],
                      Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: i == current
                              ? colorScheme.onPrimary
                              : colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final Map<String, dynamic> option;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;

  const _OptionTile({
    required this.option,
    required this.selected,
    required this.multi,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final key = FormFieldShape.optionKey(option);
    final label = FormFieldShape.optionLabel(option, key);
    final description = FormFieldShape.asString(option['description']) ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? colorScheme.primaryContainer.withValues(alpha: 0.6)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? colorScheme.primary : colorScheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  multi
                      ? (selected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank)
                      : (selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked),
                  size: 18,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(fontSize: 14)),
                      if (description.isNotEmpty)
                        Text(
                          description,
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 停靠卡里的表单：能分页就分页，否则退回平铺的 [FormBubble]。
class DockedFormBody extends StatelessWidget {
  final Map<String, dynamic> formData;
  final void Function(
          String formId, Map<String, dynamic> values, String summary)
      onFormSubmitted;
  final void Function(String formId)? onFormDeclined;

  const DockedFormBody({
    super.key,
    required this.formData,
    required this.onFormSubmitted,
    this.onFormDeclined,
  });

  @override
  Widget build(BuildContext context) {
    if (PagedFormPanel.supports(formData)) {
      return PagedFormPanel(
        formData: formData,
        onFormSubmitted: onFormSubmitted,
        onFormDeclined: onFormDeclined,
      );
    }
    return FormBubble(
      formData: formData,
      onFormSubmitted: onFormSubmitted,
      onFormDeclined: onFormDeclined,
    );
  }
}
