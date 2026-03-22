import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show kIsWeb;

/// 工具执行结果的类型标识
///
/// - [text]          纯文本，例如 shell 输出、文件内容、搜索结果
/// - [contentBlocks] 多模态内容块数组（兼容 Claude content[] 格式），
///                   例如 "截图 + 说明文字"、"图表 + 数值"
/// - [binaryRef]     大型二进制文件引用（图片/音频），
///                   base64 不内联存储，只记录本地路径和 MIME，
///                   重建上下文时通过 [toClaudeContentAsync] 按需读取
enum ToolResultType { text, contentBlocks, binaryRef }

/// 工具执行结果的统一封装。
///
/// ### 设计目标
/// 1. 统一三种结果形态，让上层代码无需关心具体类型
/// 2. [summary] 始终是可直接放入 LLM 上下文的压缩文本（≤300 字符）
/// 3. [serialized] 是完整结果的 JSON 序列化字符串，存入 `tool_executions.full_result`
/// 4. [typeString] 对应 `tool_executions.result_type` 列的值
/// 5. [toClaudeContent] / [toClaudeContentAsync] 供历史重建时还原为 Claude 格式
/// 6. [toOpenAIContent] 供历史重建时还原为 OpenAI tool message 的 content 字段
///
/// ### 使用示例
/// ```dart
/// // 纯文本（最常见）
/// final r = ToolExecutionResult.text(shellOutput);
///
/// // 截图 + 文字说明（Claude 多模态）
/// final r = ToolExecutionResult.contentBlocks([
///   {'type': 'text', 'text': '执行结果如下：'},
///   {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': b64}},
/// ]);
///
/// // 大文件只存路径
/// final r = ToolExecutionResult.binaryRef(
///   filePath: '/tmp/screenshot.png',
///   mimeType: 'image/png',
///   label: '屏幕截图',
/// );
/// ```
class ToolExecutionResult {
  /// 结果类型
  final ToolResultType type;

  /// 完整结果的 JSON 序列化字符串，对应数据库 `full_result` 列
  final String serialized;

  /// 压缩摘要，对应数据库 `summary` 列，注入 LLM 上下文时使用
  final String summary;

  const ToolExecutionResult._({
    required this.type,
    required this.serialized,
    required this.summary,
  });

  // ---------------------------------------------------------------------------
  // 工厂构造
  // ---------------------------------------------------------------------------

  /// 纯文本结果（最常见场景）。
  ///
  /// [text] 工具的完整文本输出（shell stdout、文件内容、API 响应等）。
  /// [summaryMaxChars] 摘要截断阈值，默认 300 字符。
  factory ToolExecutionResult.text(
    String text, {
    int summaryMaxChars = 300,
  }) {
    final serialized = jsonEncode({'type': 'text', 'text': text});
    final summary = _truncateText(text, summaryMaxChars);
    return ToolExecutionResult._(
      type: ToolResultType.text,
      serialized: serialized,
      summary: summary,
    );
  }

  /// 多模态内容块结果，兼容 Anthropic content block 规范。
  ///
  /// [blocks] 的每个元素是一个 content block，例如：
  /// ```dart
  /// {'type': 'text', 'text': '分析结果：'}
  /// {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': '...'}}
  /// ```
  ///
  /// 摘要策略：合并所有 text block 内容（截至 250 字符）+ 标注图片数量。
  factory ToolExecutionResult.contentBlocks(
    List<Map<String, dynamic>> blocks,
  ) {
    final serialized = jsonEncode(blocks);

    final textParts = blocks
        .where((b) => b['type'] == 'text')
        .map((b) => (b['text'] as String?) ?? '')
        .where((s) => s.isNotEmpty)
        .join(' ');
    final imageCount = blocks.where((b) => b['type'] == 'image').length;

    final textPreview = _truncateText(textParts, 250, omitSuffix: true);
    final imageSuffix = imageCount > 0
        ? ' [$imageCount image${imageCount > 1 ? 's' : ''}'
            ' — use get_tool_result for full content]'
        : '';

    final summary = textPreview.isEmpty && imageCount > 0
        ? '[$imageCount image${imageCount > 1 ? 's' : ''}'
            ' — use get_tool_result for full content]'
        : '$textPreview$imageSuffix';

    return ToolExecutionResult._(
      type: ToolResultType.contentBlocks,
      serialized: serialized,
      summary: summary.isEmpty ? '[content blocks — use get_tool_result for details]' : summary,
    );
  }

  /// 大型二进制文件引用，不内联 base64，只存路径和 MIME。
  ///
  /// 适用于截图、录音等超过几百 KB 的文件，避免数据库膨胀。
  /// 重建历史时调用 [toClaudeContentAsync] 会读取文件并转换为 base64 block。
  ///
  /// [filePath]  文件的本地绝对路径（由调用方负责写入磁盘）
  /// [mimeType]  MIME 类型，例如 `'image/png'`、`'audio/wav'`
  /// [label]     可选的人类可读描述，用于摘要显示
  factory ToolExecutionResult.binaryRef({
    required String filePath,
    required String mimeType,
    String? label,
  }) {
    final payload = <String, dynamic>{
      'type': 'binary_ref',
      'file_path': filePath,
      'mime_type': mimeType,
      if (label != null) 'label': label,
    };
    final serialized = jsonEncode(payload);
    final displayLabel = label ?? filePath.split('/').last;
    final summary =
        '[$mimeType: $displayLabel — use get_tool_result for full content]';
    return ToolExecutionResult._(
      type: ToolResultType.binaryRef,
      serialized: serialized,
      summary: summary,
    );
  }

  // ---------------------------------------------------------------------------
  // 从数据库反序列化
  // ---------------------------------------------------------------------------

  /// 从数据库行还原 [ToolExecutionResult]。
  ///
  /// [resultType] 对应 `tool_executions.result_type` 列的值。
  /// [serialized] 对应 `tool_executions.full_result` 列的值。
  /// [summary]    对应 `tool_executions.summary` 列的值。
  factory ToolExecutionResult.fromDb({
    required String resultType,
    required String serialized,
    required String summary,
  }) {
    return ToolExecutionResult._(
      type: _typeFromString(resultType),
      serialized: serialized,
      summary: summary,
    );
  }

  // ---------------------------------------------------------------------------
  // 还原为 LLM 上下文格式
  // ---------------------------------------------------------------------------

  /// 将完整结果同步还原为 Claude `tool_result` content 字段的值。
  ///
  /// | 类型           | 返回值                              |
  /// |---------------|-------------------------------------|
  /// | text          | `String`                            |
  /// | contentBlocks | `List<Map<String, dynamic>>`        |
  /// | binaryRef     | `String`（占位，请用异步版本获取图片） |
  dynamic toClaudeContent() {
    switch (type) {
      case ToolResultType.text:
        final decoded = jsonDecode(serialized) as Map<String, dynamic>;
        return decoded['text'] as String;

      case ToolResultType.contentBlocks:
        return (jsonDecode(serialized) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

      case ToolResultType.binaryRef:
        // 同步路径无法读文件，降级为占位文本
        final ref = jsonDecode(serialized) as Map<String, dynamic>;
        final label = ref['label'] as String? ?? ref['file_path'] as String;
        return '[Binary: $label (${ref['mime_type']}) — use get_tool_result to load]';
    }
  }

  /// 异步版本：`binaryRef` 会读取文件字节并转为 base64 image block。
  ///
  /// 其他类型行为与 [toClaudeContent] 一致。
  Future<dynamic> toClaudeContentAsync() async {
    if (type != ToolResultType.binaryRef) return toClaudeContent();
    if (kIsWeb) return toClaudeContent(); // Web 不支持本地文件

    final ref = jsonDecode(serialized) as Map<String, dynamic>;
    final filePath = ref['file_path'] as String;
    final mimeType = ref['mime_type'] as String;

    try {
      final bytes = await File(filePath).readAsBytes();
      final b64 = base64Encode(bytes);
      return [
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': mimeType,
            'data': b64,
          },
        }
      ];
    } catch (_) {
      return '[Failed to load binary file: $filePath]';
    }
  }

  /// 还原为 OpenAI tool message 的 `content` 字符串。
  ///
  /// OpenAI 目前只接受字符串，图片须通过 user 消息的 image_url 传入。
  ///
  /// | 类型           | 返回值                                     |
  /// |---------------|---------------------------------------------|
  /// | text          | 原始文本                                    |
  /// | contentBlocks | 合并所有 text block；图片附注说明           |
  /// | binaryRef     | 占位文本                                    |
  String toOpenAIContent() {
    switch (type) {
      case ToolResultType.text:
        final decoded = jsonDecode(serialized) as Map<String, dynamic>;
        return decoded['text'] as String;

      case ToolResultType.contentBlocks:
        final blocks = (jsonDecode(serialized) as List)
            .cast<Map<String, dynamic>>();
        final texts = blocks
            .where((b) => b['type'] == 'text')
            .map((b) => (b['text'] as String?) ?? '')
            .where((s) => s.isNotEmpty)
            .join('\n');
        final imageCount = blocks.where((b) => b['type'] == 'image').length;
        if (imageCount > 0) {
          return '$texts\n[$imageCount image(s) omitted — OpenAI tool results do not support images]'
              .trim();
        }
        return texts;

      case ToolResultType.binaryRef:
        final ref = jsonDecode(serialized) as Map<String, dynamic>;
        final label = ref['label'] as String? ?? ref['file_path'] as String;
        return '[Binary file: $label (${ref['mime_type']})]';
    }
  }

  // ---------------------------------------------------------------------------
  // 辅助属性
  // ---------------------------------------------------------------------------

  /// 对应数据库 `result_type` 列的字符串值
  String get typeString => _typeToString(type);

  // ---------------------------------------------------------------------------
  // 私有工具方法
  // ---------------------------------------------------------------------------

  /// 截断文本，生成摘要。
  ///
  /// [omitSuffix] 为 true 时不附加长度提示（由外层自行拼接）。
  static String _truncateText(
    String text,
    int maxChars, {
    bool omitSuffix = false,
  }) {
    if (text.length <= maxChars) return text;
    final preview = text.substring(0, maxChars);
    if (omitSuffix) return preview;
    return '$preview… [${text.length} chars total'
        ' — use get_tool_result for full result]';
  }

  static ToolResultType _typeFromString(String s) {
    switch (s) {
      case 'content_blocks':
        return ToolResultType.contentBlocks;
      case 'binary_ref':
        return ToolResultType.binaryRef;
      case 'text':
      default:
        return ToolResultType.text;
    }
  }

  static String _typeToString(ToolResultType t) {
    switch (t) {
      case ToolResultType.contentBlocks:
        return 'content_blocks';
      case ToolResultType.binaryRef:
        return 'binary_ref';
      case ToolResultType.text:
        return 'text';
    }
  }

  @override
  String toString() =>
      'ToolExecutionResult(type: $typeString, summaryLength: ${summary.length})';
}
