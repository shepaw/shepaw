import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/agent_workspace_uris.dart';
import 'package:shepaw/storage/workspace_link_resolver.dart';

void main() {
  const root = 'pouch://workspaces/Users/foo/proj/';

  test('relative markdown href joins the mapped workspace', () {
    expect(isRelativeWorkspaceHref('docs/good.md'), isTrue);
    expect(isRelativeWorkspaceHref('./docs/good.md'), isTrue);
    expect(isRelativeWorkspaceHref('https://example.com/a'), isFalse);
    expect(isRelativeWorkspaceHref('pouch://files/a.md'), isFalse);

    expect(
      resolveWorkspaceHref('docs/good.md', [root]),
      'pouch://workspaces/Users/foo/proj/docs/good.md',
    );
    expect(
      resolveWorkspaceHref('./lib/main.dart', [root]),
      'pouch://workspaces/Users/foo/proj/lib/main.dart',
    );
  });

  test('工作区地址补目录斜杠（不再有设备优先形态）', () {
    expect(
      canonicalizeStoreWorkspaceUri(
        'pouch://workspaces/Users/foo/proj',
      ),
      'pouch://workspaces/Users/foo/proj/',
    );
  });

  test('pouch:// hrefs pass through; http is left to the browser', () {
    expect(
      resolveWorkspaceHref('pouch://workspaces/other.md', [root]),
      'pouch://workspaces/other.md',
    );
    expect(resolveWorkspaceHref('https://ex.com/x', [root]), isNull);
    expect(joinStoreUri(root, '../secret'), isNull);
  });

  test('metadata workspace_uri is collected', () {
    expect(
      workspaceUrisFromMetadata({
        'workspace_uri': 'pouch://workspaces/Users/foo/proj',
      }),
      ['pouch://workspaces/Users/foo/proj/'],
    );
    expect(
      workspaceUrisFromMetadata({
        'workspaceUri': 'pouch://workspaces/Users/foo/proj',
      }),
      ['pouch://workspaces/Users/foo/proj/'],
    );
  });
}
