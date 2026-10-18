/// thinking / 工具进度（`metadata.progress_content`）的长度上限。
///
/// 一个长回合的 thinking 可以累积到几百 KB（实测有 295 KB 的会话），
/// 落库、JSON 序列化、以及展开时的 Markdown 解析都会被拖慢。
/// 超过上限后保留开头一小段和最近的尾部，中间用省略标记代替——最近的
/// 步骤通常才是用户要看的。
const int kMaxProgressContentChars = 32768;
const int kProgressContentHeadChars = 8192;

/// 追加时的高水位：超过它才裁剪一次，避免每收到一块都复制整个字符串。
const int kProgressContentTrimThresholdChars = 49152;

/// 把 [content] 裁到 [kMaxProgressContentChars] 以内（保留头尾）。
String capProgressContent(String content) {
  if (content.length <= kMaxProgressContentChars) return content;
  var headEnd = kProgressContentHeadChars;
  // 不要把代理对切成两半。
  if (headEnd < content.length &&
      _isLowSurrogate(content.codeUnitAt(headEnd))) {
    headEnd--;
  }
  var tailStart =
      content.length - (kMaxProgressContentChars - kProgressContentHeadChars);
  if (_isLowSurrogate(content.codeUnitAt(tailStart))) {
    tailStart--;
  }
  final head = content.substring(0, headEnd);
  final omitted = content.length - kMaxProgressContentChars;
  return '$head\n\n…（中间省略 $omitted 字符）\n\n'
      '${content.substring(tailStart)}';
}

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// 流式追加；只在超过高水位后裁剪，保持均摊成本为常数。
String appendProgressContent(String content, String chunk) {
  final next = content + chunk;
  if (next.length <= kProgressContentTrimThresholdChars) return next;
  return capProgressContent(next);
}
