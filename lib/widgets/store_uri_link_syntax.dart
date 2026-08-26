import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

import '../storage/store_protocol.dart';

/// 把聊天正文里「裸写」的合法 `store://` URI 自动转成可点击链接。
///
/// markdown 的 autolink 扩展只识别 http/https/ftp/www，不认 `store://`；
/// 本语法在解析阶段把符合 `store://<space>/<16-hex-device>/<path…>` 形态的
/// 文本渲染成 `<a href="store://…">`，链接文本取路径最后一段（文件名）。
/// 点击后走 flutter_markdown 的 onTapLink → `StoreOpenService.openStoreUri`。
///
/// 只匹配严格形态（space 语法合法、device 为 16 位 hex），因此文档模板里的
/// `store://<space>/<device>/<path>` 或 `store://xxx` 不会被误链接化。
/// 依赖 markdown 解析器的既有保护：行内代码/围栏代码块/已有 `[text](url)`
/// 链接内的文本不会进入本语法。
class StoreUriLinkSyntax extends md.InlineSyntax {
  StoreUriLinkSyntax() : super(_pattern, startCharacter: 's'.codeUnitAt(0));

  static const _pattern = r'store://[a-z][a-z0-9-]*/[0-9a-f]{16}/'
      r'[^\s<>\[\](){}"`，。、；：！？…]+';

  /// 句末标点（英文句点也在内：保护 `snake-game.html。` 这类正文场景）。
  static const _trailingPunct = <String>{
    '.', ',', ';', ':', '!', '?',
    '，', '。', '、', '；', '：', '！', '？', '…',
  };

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    startMatchPos ??= parser.pos;
    final match = pattern.matchAsPrefix(parser.source, startMatchPos);
    if (match == null) return false;

    var consume = match.group(0)!.length;
    while (consume > _minUriLength &&
        _trailingPunct.contains(match.group(0)![consume - 1])) {
      consume--;
    }
    if (consume <= _minUriLength) return false;
    final uri = match.group(0)!.substring(0, consume);

    final String display;
    try {
      final parsed = parseStoreUri(uri);
      final base = p.basename(parsed.path);
      display = base.isEmpty ? uri : base;
    } catch (_) {
      // 非法 URI（如 `store://xxx`）：不消费，让文本原样走其它语法。
      return false;
    }

    parser.writeText();
    final anchor = md.Element.text('a', display)
      ..attributes['href'] = uri;
    parser
      ..addNode(anchor)
      ..consume(consume);
    return true;
  }

  /// 基类的抽象钩子；解析逻辑已整体放在 [tryMatch] 里，本方法不会被调用。
  @override
  bool onMatch(md.InlineParser parser, Match match) => false;

  static const _minUriLength = 'store://'.length;
}
