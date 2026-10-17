import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/services/cli_language.dart';

void main() {
  test('界面语言收成 CLI 认的 en 或 zh', () {
    expect(cliLanguageTag('en'), 'en');
    expect(cliLanguageTag('en-US'), 'en');
    expect(cliLanguageTag('zh'), 'zh');
    expect(cliLanguageTag('zh-Hans'), 'zh');
    expect(cliLanguageTag('fr'), 'zh');
    expect(cliLanguageTag(null), 'zh');
  });

  test('调用 shepaw 时把当前语言放在 --lang 上', () {
    expect(
      shepawArgs(const ['status', '--json'], languageCode: 'en'),
      ['--lang', 'en', 'status', '--json'],
    );
    expect(
      shepawArgs(const ['start'], languageCode: 'zh'),
      ['--lang', 'zh', 'start'],
    );
    expect(
      shepawArgs(const ['pair'], languageCode: 'fr'),
      ['--lang', 'zh', 'pair'],
    );
  });

  test('语言文件写在 hub 目录，内容和 CLI 读的一样', () async {
    final root = Directory.systemTemp.createTempSync('shepaw-lang');
    addTearDown(() => root.deleteSync(recursive: true));

    await writeCliLanguageFile('en', hubRoot: root.path);
    final file = File(p.join(root.path, 'lang'));
    expect(file.readAsStringSync(), 'en\n');

    await writeCliLanguageFile('en', hubRoot: root.path);
    expect(file.readAsStringSync(), 'en\n');

    await writeCliLanguageFile('zh-Hans', hubRoot: root.path);
    expect(file.readAsStringSync(), 'zh\n');
  });
}
