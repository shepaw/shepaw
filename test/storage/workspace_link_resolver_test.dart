import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/agent_workspace_uris.dart';
import 'package:shepaw/storage/workspace_link_resolver.dart';

void main() {
  const root = 'pouch://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/';

  test('relative markdown href joins the mapped workspace', () {
    expect(isRelativeWorkspaceHref('docs/good.md'), isTrue);
    expect(isRelativeWorkspaceHref('./docs/good.md'), isTrue);
    expect(isRelativeWorkspaceHref('https://example.com/a'), isFalse);
    expect(isRelativeWorkspaceHref('pouch://files/aaaaaaaaaaaaaaaa/a.md'), isFalse);

    expect(
      resolveWorkspaceHref('docs/good.md', [root]),
      'pouch://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/docs/good.md',
    );
    expect(
      resolveWorkspaceHref('./lib/main.dart', [root]),
      'pouch://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/lib/main.dart',
    );
  });

  test('device-first store URI is rewritten to space-first', () {
    expect(
      canonicalizeStoreWorkspaceUri(
        'pouch://aaaaaaaaaaaaaaaa/workspaces/Users/foo/proj',
      ),
      'pouch://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/',
    );
    expect(
      canonicalizeStoreWorkspaceUri(
        'pouch://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj',
      ),
      'pouch://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/',
    );
  });

  test('pouch:// hrefs pass through; http is left to the browser', () {
    expect(
      resolveWorkspaceHref('pouch://workspaces/aaaaaaaaaaaaaaaa/other.md', [root]),
      'pouch://workspaces/aaaaaaaaaaaaaaaa/other.md',
    );
    expect(resolveWorkspaceHref('https://ex.com/x', [root]), isNull);
    expect(joinStoreUri(root, '../secret'), isNull);
  });

  test('metadata workspace_uri is collected', () {
    expect(
      workspaceUrisFromMetadata({
        'workspace_uri': 'pouch://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj',
      }),
      ['pouch://workspaces/aaaaaaaaaaaaaaaa/Users/foo/proj/'],
    );
    expect(
      workspaceUrisFromMetadata({
        'workspaceUri': 'pouch://bbbbbbbbbbbbbbbb/workspaces/Users/foo/proj',
      }),
      ['pouch://workspaces/bbbbbbbbbbbbbbbb/Users/foo/proj/'],
    );
  });
}
