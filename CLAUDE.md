# Claude 工作规范

## AI 中间产物目录

**所有由 AI 推理过程生成的文件，必须保存在 `.ai_workspace/` 目录下。**

包括但不限于：
- 代码分析报告（`*_ANALYSIS.md`、`*_FINDINGS.md`）
- 架构图和可视化文档（`*_DIAGRAM.md`、`*_VISUAL*.md`）
- 快速参考文档（`*_QUICK_REFERENCE.md`、`*_INDEX.md`）
- 探索摘要（`*_EXPLORATION*.md`、`*_SUMMARY.md`）
- 实现指南和工作日志（`*_GUIDE.md`、`*_WORK_LOG.md`）
- 任何临时性的中间分析文档

**读取已有中间产物时，优先从 `.ai_workspace/` 目录查找。**

项目根目录只保留正式文档：`README.md`、`README_CN.md`、`README_EN.md`、`BUILD_GUIDE.md`。

`.ai_workspace/` 已加入 `.gitignore`，不会被提交到版本库。
