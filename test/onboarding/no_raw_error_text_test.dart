import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 门页上不许出现原始错误。
///
/// 以前好几处是 `Text('$error')`，用户看到的是 `StateError: 没有这只袋子`、
/// `TimeoutException after 0:00:15`。错误要先过 `mapGateError` + `gateErrorTitle`。
/// 这里守着这条规则，免得以后又有人图省事直接把错误摆上去。
void main() {
  final dir = Directory('lib/onboarding');
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  test('lib/onboarding 下有文件可查', () {
    expect(files.length, greaterThan(5));
  });

  final banned = <RegExp>[
    // Text('$error') / Text(error.toString())
    RegExp(r"Text\(\s*'\$error'"),
    RegExp(r'Text\(\s*\$\{?error'),
    RegExp(r'Text\(\s*error\.(toString|message|runtimeType)\(\)'),
    // _error = '$error'
    RegExp(r"_error\s*=\s*'\$error'"),
    RegExp(r'_error\s*=\s*\$?\{?error\.toString\(\)'),
  ];

  for (final file in files) {
    final path = file.path.replaceAll('\\', '/');
    if (path.endsWith('gate_errors.dart')) continue; // 这里是翻译错误的地方
    test('$path 不直接显示原始错误', () {
      final source = file.readAsStringSync();
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        for (final pattern in banned) {
          expect(
            pattern.hasMatch(line),
            isFalse,
            reason: '$path:${i + 1} 直接显示了原始错误：${line.trim()}',
          );
        }
      }
    });
  }
}
