/// URL 验证与规范化工具
library;

/// 验证并规范化 URL
/// 
/// - 去除前后空格
/// - 自动补充 https:// 前缀（如果缺少 http/https）
/// - 返回 Uri 对象，或 null 如果格式无效
Uri? parseAndValidateUrl(String urlStr) {
  try {
    var url = urlStr.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    return Uri.parse(url);
  } catch (_) {
    return null;
  }
}
