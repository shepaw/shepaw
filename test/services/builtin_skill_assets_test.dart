import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// pubspec 的目录资产条目**不递归**：`assets/skills/` 只收该目录下的直接
/// 文件，而那里全是子目录，于是内置技能一个文件都没进包，`_seedBuiltinSkills`
/// 与 `_publishSystemSkill` 双双静默失败（线上表现为 She 读到
/// `store://tools/<device>/skills/shepaw-system/SKILL.md` 时 not_found）。
///
/// 这组断言盯住打包结果，而不是源码目录是否存在。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const systemSkill = 'assets/skills/shepaw-system/SKILL.md';
  const appGuide = 'assets/skills/app-usage-guide/SKILL.md';
  const appGuideRefPrefix = 'assets/skills/app-usage-guide/references/';

  test('内置技能资产进了 AssetManifest', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys = manifest.listAssets();

    expect(keys, contains(systemSkill));
    expect(keys, contains(appGuide));
    expect(
      keys.where((k) => k.startsWith(appGuideRefPrefix)),
      isNotEmpty,
      reason: 'app-usage-guide 的 references/ 也是子目录，必须单独列条目',
    );
  });

  test('系统技能全文可 load（每轮 scope card 给的地址依赖它）', () async {
    final data = await rootBundle.load(systemSkill);
    expect(data.lengthInBytes, greaterThan(0));
  });
}
