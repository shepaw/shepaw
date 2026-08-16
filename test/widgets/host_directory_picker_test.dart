import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/widgets/host_directory_picker.dart';

void main() {
  test('resolveLocalBrowsePath defaults empty to home', () {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    expect(home, isNotNull);
    expect(resolveLocalBrowsePath(null), home);
    expect(resolveLocalBrowsePath(''), home);
    expect(resolveLocalBrowsePath('~'), home);
  });

  test('splitHostPathQuery splits parent and prefix', () {
    expect(
      splitHostPathQuery('/Users/me/pro'),
      (parent: '/Users/me', prefix: 'pro'),
    );
    expect(
      splitHostPathQuery('/Users/me/'),
      (parent: '/Users/me', prefix: ''),
    );
    expect(splitHostPathQuery('/'), (parent: '/', prefix: ''));
    expect(
      splitHostPathQuery('relative'),
      (parent: '', prefix: 'relative'),
    );
  });

  test('browseLocalDirectory lists only directories under home', () async {
    final result = await browseLocalDirectory(null);
    expect(result.path, isNotEmpty);
    for (final e in result.entries) {
      expect(Directory(e.path).existsSync(), isTrue);
    }
  });
}
