import 'dart:convert';

import 'catalog.dart';

/// 参数校验结果。规则与 Rust `shepaw_command::validate_params` 相同。
class SpecCheck {
  const SpecCheck._({
    required this.ok,
    this.code,
    this.message,
    this.args,
  });

  final bool ok;
  final String? code;
  final String? message;
  final Map<String, Object?>? args;

  static const unknown = SpecCheck._(
    ok: false,
    code: 'unknown_command',
    message: 'unknown command',
  );
}

Map<String, dynamic>? _catalog;

Map<String, dynamic> commandCatalog() {
  return _catalog ??= jsonDecode(catalogJson) as Map<String, dynamic>;
}

SpecCheck validateCommand(String command, Object? args) {
  final catalog = commandCatalog();
  final commands = catalog['commands'] as List<dynamic>;
  Map<String, dynamic>? spec;
  for (final item in commands) {
    final commandSpec = item as Map<String, dynamic>;
    if (commandSpec['id'] == command) {
      spec = commandSpec;
      break;
    }
  }
  if (spec == null) {
    return SpecCheck.unknown;
  }
  final schema = spec['params'] as Map<String, dynamic>;
  return _validateParams(schema, args);
}

SpecCheck _validateParams(Map<String, dynamic> schema, Object? args) {
  if (args is! Map) {
    return const SpecCheck._(
      ok: false,
      code: 'invalid_args',
      message: 'arguments must be a JSON object',
    );
  }
  final input = args.map((key, value) => MapEntry(key.toString(), value));
  final properties = (schema['properties'] as Map?)?.map(
        (key, value) => MapEntry(key.toString(), value as Map<String, dynamic>),
      ) ??
      <String, Map<String, dynamic>>{};
  final additional = schema['additionalProperties'] as bool? ?? false;
  if (!additional) {
    for (final key in input.keys) {
      if (!properties.containsKey(key)) {
        return SpecCheck._(
          ok: false,
          code: 'invalid_args',
          message: 'unexpected argument $key',
        );
      }
    }
  }
  final required = (schema['required'] as List?)?.map((item) => item.toString()) ??
      const <String>[];
  for (final name in required) {
    if (!input.containsKey(name) || input[name] == null) {
      return SpecCheck._(
        ok: false,
        code: 'invalid_args',
        message: 'missing argument $name',
      );
    }
  }
  final normalized = <String, Object?>{};
  for (final entry in properties.entries) {
    final name = entry.key;
    final property = entry.value;
    if (input.containsKey(name)) {
      final value = input[name];
      if (value == null) {
        return SpecCheck._(
          ok: false,
          code: 'invalid_args',
          message: 'missing argument $name',
        );
      }
      final checked = _checkProperty(name, property, value);
      if (!checked.ok) {
        return checked;
      }
      normalized[name] = checked.args!['value'];
    } else if (property.containsKey('default')) {
      normalized[name] = property['default'] as Object?;
    }
  }
  return SpecCheck._(ok: true, args: normalized);
}

SpecCheck _checkProperty(String name, Map<String, dynamic> property, Object value) {
  final kind = property['type'] as String? ?? '';
  switch (kind) {
    case 'string':
      if (value is! String) {
        return _bad('$name must be a string');
      }
      final minLength = property['minLength'] as int?;
      if (minLength != null && value.runes.length < minLength) {
        return _bad('$name is too short');
      }
      final maxLength = property['maxLength'] as int?;
      if (maxLength != null && value.runes.length > maxLength) {
        return _bad('$name is too long');
      }
      final enumValues = property['enum'] as List?;
      if (enumValues != null && !enumValues.contains(value)) {
        return _bad('$name is not an allowed value');
      }
      return SpecCheck._(ok: true, args: {'value': value});
    case 'integer':
      if (value is! int) {
        return _bad('$name must be an integer');
      }
      final minimum = property['minimum'] as int?;
      if (minimum != null && value < minimum) {
        return _bad('$name is below the minimum');
      }
      final maximum = property['maximum'] as int?;
      if (maximum != null && value > maximum) {
        return _bad('$name is above the maximum');
      }
      return SpecCheck._(ok: true, args: {'value': value});
    case 'number':
      if (value is! num) {
        return _bad('$name must be a number');
      }
      final minimum = property['minimum'] as num?;
      if (minimum != null && value < minimum) {
        return _bad('$name is below the minimum');
      }
      final maximum = property['maximum'] as num?;
      if (maximum != null && value > maximum) {
        return _bad('$name is above the maximum');
      }
      return SpecCheck._(ok: true, args: {'value': value});
    case 'boolean':
      if (value is! bool) {
        return _bad('$name must be a boolean');
      }
      return SpecCheck._(ok: true, args: {'value': value});
    default:
      return _bad('$name has an unsupported type');
  }
}

SpecCheck _bad(String message) {
  return SpecCheck._(ok: false, code: 'invalid_args', message: message);
}
