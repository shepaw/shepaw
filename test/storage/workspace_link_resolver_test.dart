import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/agent_workspace_uris.dart';
import 'package:shepaw/storage/workspace_link_resolver.dart';

void main() {
  const root = 'store://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/';

  test('relative markdown href joins the mapped workspace', () {
    expect(isRelativeWorkspaceHref('docs/good.md'), isTrue);
    expect(isRelativeWorkspaceHref('./docs/good.md'), isTrue);
    expect(isRelativeWorkspaceHref('https://example.com/a'), isFalse);
    expect(isRelativeWorkspaceHref('store://files/aaaaaaaaaaaaaaaa/a.md'), isFalse);

    expect(
      resolveWorkspaceHref('docs/good.md', [root]),
      'store://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/docs/good.md',
    );
    expect(
      resolveWorkspaceHref('./lib/main.dart', [root]),
      'store://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/lib/main.dart',
    );
  });

  test('store:// hrefs pass through; http is left to the browser', () {
    expect(
      resolveWorkspaceHref('store://workspaces/aaaaaaaaaaaaaaaa/other.md', [root]),
      'store://workspaces/aaaaaaaaaaaaaaaa/other.md',
    );
    expect(resolveWorkspaceHref('https://ex.com/x', [root]), isNull);
    expect(joinStoreUri(root, '../secret'), isNull);
  });

  test('metadata workspace_uri is collected', () {
    expect(
      workspaceUrisFromMetadata({
        'workspace_uri': 'store://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj',
      }),
      ['store://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/'],
    );
  });
}
