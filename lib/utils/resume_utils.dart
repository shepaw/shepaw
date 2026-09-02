/// 简历（resume）展示与建议职责的纯函数工具。
class ResumeUtils {
  ResumeUtils._();

  /// 把简历压成一行职责建议：折叠连续空白/换行并截断。
  ///
  /// 供建群页「从简历填充」使用——She 基于成员简历快速起草本群职责，
  /// 得到一行可继续编辑的草稿。空简历 / 全空白返回 null。
  static String? resumeToOneLine(String? bio, {int maxChars = 80}) {
    final raw = bio?.trim();
    if (raw == null || raw.isEmpty) return null;
    final folded = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (folded.isEmpty) return null;
    if (folded.length <= maxChars) return folded;
    return '${folded.substring(0, maxChars)}…';
  }
}
