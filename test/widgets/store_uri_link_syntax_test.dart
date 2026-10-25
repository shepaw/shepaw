import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shepaw/widgets/store_uri_link_syntax.dart';

/// 聊天正文里裸 `pouch://` URI 的自动链接化。
void main() {
  const uri = 'pouch://workspaces/group_x/snake-game.html';

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

  group('裸 pouch:// URI', () {
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
      const dirUri = 'pouch://workspaces/group_x/notes';
      final links = parseLinks(dirUri);
      expect(links, hasLength(1));
      expect(links.single.href, dirUri);
      expect(links.single.text, 'notes');
    });

    test('v3 地址（袋子 id 开头是数字）也能链接化', () {
      const v3 = 'pouch://1fc2a95b-4d50-45d2-83e1-8e40954d1239'
          '/group:g1:shared/tasks/t1/requirement.md';
      final links = parseLinks('见 $v3');
      expect(links, hasLength(1));
      expect(links.single.href, v3);
      expect(links.single.text, 'requirement.md');
    });

    test('v3 scope 根（没有文件段）显示整条地址', () {
      const v3 = 'pouch://a95b5782-4d50-45d2-83e1-8e40954d1239/group:g1:shared';
      final links = parseLinks(v3);
      expect(links, hasLength(1));
      expect(links.single.href, v3);
      expect(links.single.text, v3);
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
    test('pouch://xxx（无 device）不链接', () {
      expect(parseLinks('pouch://xxx'), isEmpty);
    });

    test('模板占位符不链接', () {
      expect(parseLinks('pouch://<space>/<device>/<path>'), isEmpty);
    });

    test('缺路径不链接（地址不带设备段后没有 device 可校验）', () {
      expect(parseLinks('pouch://files'), isEmpty);
    });

    test('路径为空不链接', () {
      expect(parseLinks('pouch://workspaces/'), isEmpty);
    });
  });
}
