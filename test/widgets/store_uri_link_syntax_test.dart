import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shepaw/widgets/store_uri_link_syntax.dart';

/// 聊天正文里裸 `store://` URI 的自动链接化。
void main() {
  const uri = 'store://workspaces/aaaaaaaaaaaaaaaa/group_x/snake-game.html';

  List<({String href, String text})> parseLinks(String source) {
    final doc = md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      inlineSyntaxes: [StoreUriLinkSyntax()],
    );
    final nodes = doc.parseLines(const LineSplitter().convert(source));
    final links = <({String href, String text})>[];
    void walk(md.Node node) {
      if (node is md.Element) {
        if (node.tag == 'a') {
          links.add((
            href: node.attributes['href'] ?? '',
            text: node.children
                    ?.whereType<md.Text>()
                    .map((e) => e.text)
                    .join() ??
                '',
          ));
        }
        for (final child in node.children ?? const <md.Node>[]) {
          walk(child);
        }
      }
    }

    for (final node in nodes) {
      walk(node);
    }
    return links;
  }

  group('裸 store:// URI', () {
    test('渲染为链接，文本取路径末段', () {
      final links = parseLinks('下载地址 $uri');
      expect(links, hasLength(1));
      expect(links.single.href, uri);
      expect(links.single.text, 'snake-game.html');
    });

    test('尾部中文标点不进 href', () {
      final links = parseLinks('下载地址 $uri。');
      expect(links, hasLength(1));
      expect(links.single.href, uri);
    });

    test('尾部英文句点不进 href', () {
      final links = parseLinks('download $uri.');
      expect(links, hasLength(1));
      expect(links.single.href, uri);
    });

    test('带 @v1 版本引用保留在 href，显示名仍为文件名', () {
      final links = parseLinks('$uri@v1');
      expect(links, hasLength(1));
      expect(links.single.href, '$uri@v1');
      expect(links.single.text, 'snake-game.html');
    });

    test('带 ?ref 查询保留在 href', () {
      final links = parseLinks('$uri?ref=v1');
      expect(links, hasLength(1));
      expect(links.single.href, '$uri?ref=v1');
    });

    test('目录 URI（无文件末段）仍可链接', () {
      const dirUri = 'store://workspaces/aaaaaaaaaaaaaaaa/group_x/notes';
      final links = parseLinks(dirUri);
      expect(links, hasLength(1));
      expect(links.single.href, dirUri);
      expect(links.single.text, 'notes');
    });
  });

  group('不误伤既有结构', () {
    test('已包在 markdown 链接内不再嵌套', () {
      final links = parseLinks('[点我]($uri)');
      expect(links, hasLength(1));
      expect(links.single.href, uri);
      expect(links.single.text, '点我');
    });

    test('行内代码内不链接化', () {
      final links = parseLinks('用 `$uri` 打开');
      expect(links, isEmpty);
    });

    test('围栏代码块内不链接化', () {
      const source = '```\n$uri\n```';
      final links = parseLinks(source);
      expect(links, isEmpty);
    });
  });

  group('非法形态不链接化', () {
    test('store://xxx（无 device）不链接', () {
      expect(parseLinks('store://xxx'), isEmpty);
    });

    test('模板占位符不链接', () {
      expect(parseLinks('store://<space>/<device>/<path>'), isEmpty);
    });

    test('device 非 16 位 hex 不链接', () {
      expect(parseLinks('store://files/abc/readme.md'), isEmpty);
    });

    test('路径为空不链接', () {
      expect(parseLinks('store://workspaces/aaaaaaaaaaaaaaaa/'), isEmpty);
    });
  });
}
