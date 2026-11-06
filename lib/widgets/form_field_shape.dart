/// 表单字段 / 选项的宽松解析。[FormBubble] 和输入框上方的分页提问卡共用，
/// 两边对字段键、类型、选项 id 的理解必须一致，提交出去的答案才长得一样。
class FormFieldShape {
  FormFieldShape._();

  /// The stable per-field key used for storing the user's input.
  ///
  /// Accepts both the legacy `field_id` and the newer `name` / `id` keys so
  /// the widget renders forms emitted by either variant of the agent SDK.
  static String fieldKey(Map<String, dynamic> field) {
    for (final key in const ['field_id', 'name', 'id', 'key']) {
      final text = asString(field[key]);
      if (text != null && text.isNotEmpty) return text;
    }
    return '';
  }

  static String rawType(Map<String, dynamic> field) {
    return (asString(field['type']) ?? 'text_input').trim().toLowerCase();
  }

  /// Canonicalise [type] into a kind this widget knows how to render.
  ///
  /// A bare `checkbox` is a yes/no box; the same type with `options` is a
  /// checkbox group. Unknown types are returned as-is so the fallback still
  /// shows "Unknown field type".
  static String fieldKind(Map<String, dynamic> field) {
    final type = rawType(field);
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

  static bool isRequired(Map<String, dynamic> field) {
    final raw = field['required'];
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final text = asString(raw)?.trim().toLowerCase();
    return text == 'true' || text == '1' || text == 'yes' || text == 'required';
  }

  static String? asString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return '$value';
  }

  /// 只认字符串。数字、布尔值不当作 id / 作废原因，免得 `"true"` 被看成已作废。
  static String? strictString(Object? value) =>
      value is String ? value : null;

  /// 收成 `Map<String, dynamic>`。
  ///
  /// `{...existing, ...incoming}` 在 `existing is Map` 之后，字面量的运行时
  /// 类型是 `Map<dynamic, dynamic>`。`is Map<String, dynamic>` 为假，
  /// `as Map<String, dynamic>?` 直接抛。列表项在 release 里会被换成一块
  /// 尽量撑高的错误占位，整段消息区看起来像白屏。
  static Map<String, dynamic>? stringKeyMap(Object? value) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  /// 把主机再投来的卡片叠到本地那张上。
  ///
  /// 本地已经记下的作废 / 作答不被一份「还开着」的补发盖掉。
  static Map<String, dynamic> mergeCard(
    Object? existing,
    Map<String, dynamic> incoming,
  ) {
    final base = stringKeyMap(existing) ?? <String, dynamic>{};
    return Map<String, dynamic>.from(base)..addAll(incoming);
  }

  static bool asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = asString(value)?.trim().toLowerCase();
    return text == 'true' || text == '1' || text == 'yes' || text == 'on';
  }

  static List<String> asStringList(dynamic value) {
    if (value is List) {
      return value
          .map(asString)
          .whereType<String>()
          .where((item) => item.isNotEmpty)
          .toList();
    }
    final one = asString(value);
    if (one == null || one.isEmpty) return <String>[];
    return [one];
  }

  static bool isBlank(dynamic value) {
    if (value == null) return true;
    if (value is String) return value.trim().isEmpty;
    if (value is List) return value.isEmpty;
    return false;
  }

  /// The stable per-option key; accepts both the legacy `id` and the
  /// newer `value` shapes, including non-string ids.
  static String optionKey(Map<String, dynamic> option) {
    for (final key in const ['id', 'value', 'name']) {
      final text = asString(option[key]);
      if (text != null && text.isNotEmpty) return text;
    }
    return '';
  }

  static String optionLabel(Map<String, dynamic> option, String fallback) {
    for (final key in const ['label', 'text', 'name']) {
      final text = asString(option[key]);
      if (text != null && text.isNotEmpty) return text;
    }
    return fallback;
  }

  /// Options may be maps (`id`/`value` + `label`) or plain strings.
  static List<Map<String, dynamic>> normalizeOptions(dynamic raw) {
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      final Map<String, dynamic> option;
      if (item is Map) {
        option = Map<String, dynamic>.from(item);
      } else {
        final text = asString(item);
        if (text == null || text.isEmpty) continue;
        option = {'id': text, 'label': text};
      }
      var id = optionKey(option);
      if (id.isEmpty) {
        id = '__idx_$i';
        option['id'] = id;
      }
      if (!seen.add(id)) continue;
      out.add(option);
    }
    return out;
  }

  static dynamic rawInitial(Map<String, dynamic> field) {
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

  static dynamic coerceInitial(String kind, dynamic initial) {
    switch (kind) {
      case 'checkbox':
        return asBool(initial);
      case 'multi_select':
        return asStringList(initial);
      case 'text_input':
      case 'textarea':
      case 'select':
      case 'single_select':
        if (initial is List) {
          return initial.isEmpty ? '' : (asString(initial.first) ?? '');
        }
        return asString(initial) ?? '';
      default:
        return initial;
    }
  }
}
