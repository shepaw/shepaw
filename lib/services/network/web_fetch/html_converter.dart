/// HTML 与文本/Markdown 格式转换工具
library;

/// 将 HTML 转换为纯文本
/// 
/// - 移除 script 和 style 标签
/// - 移除所有 HTML 标签
/// - 解码 HTML 实体（&nbsp; 等）
/// - 规范化空白符
String htmlToPlainText(String html) {
  var text = html;
  // 移除 script 和 style 标签
  text = text.replaceAll(
    RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true),
    '',
  );
  text = text.replaceAll(
    RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true),
    '',
  );
  // 移除所有 HTML 标签
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  // 解码 HTML 实体
  text = _decodeHtmlEntities(text);
  // 规范化空白符
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text;
}

/// 将 HTML 转换为 Markdown 格式
/// 
/// - 保留标题、段落、链接等元素的结构
/// - 转换为对应的 Markdown 语法
/// - 移除 script 和 style 标签
String htmlToMarkdown(String html) {
  var markdown = html;
  
  // 移除 script 和 style 标签
  markdown = markdown.replaceAll(
    RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true),
    '',
  );
  markdown = markdown.replaceAll(
    RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true),
    '',
  );

  // 转换标题
  markdown = markdown.replaceAll(RegExp(r'<h1[^>]*>', caseSensitive: false), '# ');
  markdown = markdown.replaceAll(RegExp(r'<h2[^>]*>', caseSensitive: false), '## ');
  markdown = markdown.replaceAll(RegExp(r'<h3[^>]*>', caseSensitive: false), '### ');
  markdown = markdown.replaceAll(RegExp(r'<h4[^>]*>', caseSensitive: false), '#### ');
  markdown = markdown.replaceAll(RegExp(r'<h[1-6][^>]*>', caseSensitive: false), '##### ');
  markdown = markdown.replaceAll(RegExp(r'</h[1-6]>', caseSensitive: false), '\n');

  // 转换段落和换行
  markdown = markdown.replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n');
  markdown = markdown.replaceAll(RegExp(r'</p>', caseSensitive: false), '\n');
  markdown = markdown.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');

  // 转换链接
  final linkRegex = RegExp(r'<a\s+href=[^>]*>([^<]*)</a>', caseSensitive: false);
  markdown = markdown.replaceAllMapped(linkRegex, (match) => '[${match.group(1)}]');

  // 转换加粗和斜体
  markdown = markdown.replaceAll(RegExp(r'<(b|strong)[^>]*>', caseSensitive: false), '**');
  markdown = markdown.replaceAll(RegExp(r'</(b|strong)>', caseSensitive: false), '**');
  markdown = markdown.replaceAll(RegExp(r'<(i|em)[^>]*>', caseSensitive: false), '*');
  markdown = markdown.replaceAll(RegExp(r'</(i|em)>', caseSensitive: false), '*');

  // 转换列表项
  markdown = markdown.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n- ');
  markdown = markdown.replaceAll(RegExp(r'</li>', caseSensitive: false), '');

  // 转换块引用
  markdown = markdown.replaceAll(RegExp(r'<blockquote[^>]*>', caseSensitive: false), '\n> ');
  markdown = markdown.replaceAll(RegExp(r'</blockquote>', caseSensitive: false), '\n');

  // 移除其他所有 HTML 标签
  markdown = markdown.replaceAll(RegExp(r'<[^>]+>'), '');
  
  // 解码 HTML 实体
  markdown = _decodeHtmlEntities(markdown);
  
  // 规范化换行符
  markdown = markdown.replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n');
  
  // 规范化空白符
  markdown = markdown.replaceAll(RegExp(r' +'), ' ').trim();

  return markdown;
}

/// 解码 HTML 实体（&nbsp; &quot; &amp; 等）
String _decodeHtmlEntities(String text) {
  return text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&#34;', '"')
      .replaceAll('&#38;', '&');
}

/// 截断内容到最大字节数
/// 返回截断后的文本加上截断提示
String truncateOutput(String content, int maxSize) {
  if (content.length <= maxSize) {
    return content;
  }
  final truncated = content.substring(0, maxSize);
  return '$truncated\n\n[Content truncated: ${content.length} bytes total, '
      'showing first $maxSize bytes]';
}
