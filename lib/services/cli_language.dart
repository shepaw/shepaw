import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../peer/services/local_cli_dial.dart';

/// 和 shepaw CLI 对齐的语言。CLI 只认 `en` / `zh`。
///
/// App 实际在用的语言写到 `{hub}/lang`。CLI 每次取文案都读这个文件，
/// 所以切换语言不用重启 Hub。一次命令上的 `--lang` 仍盖过这个文件。
String cliLanguageTag(String? languageCode) {
  final value = (languageCode ?? '').trim().toLowerCase().replaceAll('_', '-');
  if (value == 'en' || value.startsWith('en-') || value == 'english') {
    return 'en';
  }
  return 'zh';
}

/// 调用本机 `shepaw` 时带上当前语言。`--lang` 盖过环境和已保存的文件。
List<String> shepawArgs(List<String> args, {String? languageCode}) {
  return [
    '--lang',
    cliLanguageTag(languageCode ?? CliLanguage.current),
    ...args
  ];
}

class CliLanguage {
  static String? _current;
  static String? _attempted;
  static String? _writtenFor;

  /// 已经同步过的语言；还没有时用系统语言，对不上就当中文。
  static String get current {
    final saved = _current;
    if (saved != null) return saved;
    try {
      return cliLanguageTag(
        WidgetsBinding.instance.platformDispatcher.locale.languageCode,
      );
    } catch (_) {
      return 'zh';
    }
  }

  /// 把界面语言写进 CLI 也读的 `lang` 文件。手机没有本机 CLI，只记住标签。
  static Future<void> sync(String languageCode, {String? hubRoot}) async {
    final tag = cliLanguageTag(languageCode);
    _current = tag;
    if (hubRoot == null && (Platform.isAndroid || Platform.isIOS)) return;
    if (_writtenFor == tag) return;
    if (_attempted == tag) return;
    _attempted = tag;
    try {
      await writeCliLanguageFile(
        tag,
        hubRoot: hubRoot ?? cliHubRootFromEnv(Platform.environment),
      );
      _writtenFor = tag;
    } catch (_) {}
  }
}

/// 写入 `{hubRoot}/lang`。内容是 `en` 或 `zh`。已经是这个值就不动文件。
Future<void> writeCliLanguageFile(
  String languageCode, {
  required String hubRoot,
}) async {
  final tag = cliLanguageTag(languageCode);
  final dir = Directory(hubRoot);
  final created = !dir.existsSync();
  if (created) {
    dir.createSync(recursive: true);
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['700', hubRoot]);
      if (result.exitCode != 0) {
        throw StateError('chmod $hubRoot 失败');
      }
    }
  }
  final file = File(p.join(hubRoot, 'lang'));
  final next = '$tag\n';
  if (file.existsSync()) {
    try {
      if (file.readAsStringSync().trim() == tag) return;
    } catch (_) {}
  }
  file.writeAsStringSync(next, flush: true);
}
