---
description: 重新构建 ShePaw 全部平台产物（Android APK/AAB + iOS + macOS）到 dist/
argument-hint: "[clean] [bump] [check]"
---

调用 Skill 工具执行 `rebuild-all-platforms`（正文在 `.claude/skills/rebuild-all-platforms/SKILL.md`），严格按其「预检 → 执行 → 验证 → 回滚」流程走，不要跳步。

参数（`$ARGUMENTS`）为空时用 skill 里的推荐默认值：

- `clean` → 给 `build_all.sh` 加 `--clean`，彻底重建
- `bump` → 构建前先 bump `pubspec.yaml` 版本号，产物并存可对比
- `check` → 构建前先跑 `flutter analyze && flutter test --exclude-tags=needs-plugins`

用户附加的其他要求：$ARGUMENTS
