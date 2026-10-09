import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/cli_bundle.dart';

void main() {
  test('版本只按数字和预发布比较', () {
    expect(compareCliVersions('0.1.0', '0.2.0'), lessThan(0));
    expect(compareCliVersions('0.1.10', '0.1.9'), greaterThan(0));
    expect(compareCliVersions('0.1.0', '0.1.0'), 0);
    expect(compareCliVersions('0.1', '0.1.0'), 0);
    expect(compareCliVersions('0.2.0-dev', '0.2.0'), lessThan(0));
    expect(compareCliVersions('0.2.0', '0.2.0-rc.1'), greaterThan(0));
    expect(compareCliVersions('nope', '0.1.0'), lessThan(0));
  });

  test('从 shepaw version 的输出里取出版本', () {
    expect(parseCliVersion('shepaw 0.1.0\n'), '0.1.0');
    expect(parseCliVersion('shepaw v1.2.3-rc.1'), '1.2.3-rc.1');
    expect(parseCliVersion(''), isNull);
  });

  test('包内版本不比已安装的新时保持原样', () {
    expect(
      planBundledCli(
        bundleExists: false,
        bundledVersion: '1.0.0',
        installedExists: false,
        installedVersion: null,
      ),
      BundledCliAction.absent,
    );
    expect(
      planBundledCli(
        bundleExists: true,
        bundledVersion: '0.1.0',
        installedExists: false,
        installedVersion: null,
      ),
      BundledCliAction.install,
    );
    expect(
      planBundledCli(
        bundleExists: true,
        bundledVersion: '0.2.0',
        installedExists: true,
        installedVersion: '0.1.0',
      ),
      BundledCliAction.upgrade,
    );
    expect(
      planBundledCli(
        bundleExists: true,
        bundledVersion: '0.1.0',
        installedExists: true,
        installedVersion: '0.2.0',
      ),
      BundledCliAction.keep,
    );
    expect(
      planBundledCli(
        bundleExists: true,
        bundledVersion: null,
        installedExists: true,
        installedVersion: '0.2.0',
      ),
      BundledCliAction.keep,
    );
  });

  test('macOS 从 .app 里找 CLI，Windows 放在 cli 子目录', () {
    expect(
      bundledCliCandidate(
        '/Applications/ShePaw.app/Contents/MacOS/ShePaw',
        operatingSystem: 'macos',
      ),
      '/Applications/ShePaw.app/Contents/Resources/shepaw',
    );
    expect(
      bundledCliCandidate(
        r'C:\Program Files\ShePaw\shepaw.exe',
        operatingSystem: 'windows',
      ),
      r'C:\Program Files\ShePaw\cli\shepaw.exe',
    );
    expect(
      bundledCliCandidate('/opt/shepaw/shepaw', operatingSystem: 'linux'),
      '/opt/shepaw/cli/shepaw',
    );
  });

  test('shell 配置只写一次 PATH', () {
    expect(
      shellRcPath(home: '/Users/eden', shell: '/bin/zsh'),
      '/Users/eden/.zshrc',
    );
    expect(
      shellRcPath(home: '/Users/eden', shell: '/usr/local/bin/fish'),
      '/Users/eden/.config/fish/config.fish',
    );
    final block = shellPathBlock('/bin/zsh');
    final once = ensureShellRc('export EDITOR=vim\n', block);
    expect(once, contains(cliPathMarker));
    expect(once, contains(r'export PATH="$HOME/.shepaw/bin:$PATH"'));
    expect(ensureShellRc(once, block), once);
    expect(
      shellPathBlock('/opt/homebrew/bin/fish'),
      contains('fish_add_path --prepend'),
    );
  });

  test('Windows 用户 PATH 已有安装目录就不再追加', () {
    const bin = r'C:\Users\张三\AppData\Local\Shepaw\bin';
    expect(windowsUserPathContains(null, bin), isFalse);
    expect(
      windowsUserPathWithBin(r'C:\Windows', bin),
      '$bin;C:\\Windows',
    );
    final withBin = windowsUserPathWithBin(r'C:\Windows', bin);
    expect(windowsUserPathContains(withBin.toLowerCase(), bin), isTrue);
    expect(windowsUserPathWithBin(withBin, bin), withBin);
  });
}
