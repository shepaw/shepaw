import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/services/cli_host.dart';

void main() {
  test('没有 HOME 时用 USERPROFILE，和 CLI 的 hub 目录一致', () {
    expect(
      CliHost.hubRootFromEnv(
        const {'USERPROFILE': r'C:\Users\张三'},
        style: p.Style.windows,
      ),
      r'C:\Users\张三\.config\shepaw-hub',
    );
    expect(
      CliHost.hubRootFromEnv(
        const {
          'HOME': '/Users/eden',
          'USERPROFILE': r'C:\ignored',
        },
      ),
      '/Users/eden/.config/shepaw-hub',
    );
    expect(
      CliHost.hubRootFromEnv(
        const {
          'XDG_CONFIG_HOME': '/tmp/xdg',
          'HOME': '/Users/eden',
        },
      ),
      '/tmp/xdg/shepaw-hub',
    );
    expect(
      CliHost.hubRootFromEnv(const {'SHEPAW_HUB_HOME': '/custom/hub'}),
      '/custom/hub',
    );
  });

  test('安装目录按系统分开，调试构建才看开发目录', () {
    expect(
      CliHost.installedBinaryFromEnv(
        const {'HOME': '/Users/eden'},
        windows: false,
      ),
      '/Users/eden/.shepaw/bin/shepaw',
    );
    expect(
      CliHost.installedBinaryFromEnv(
        const {'LOCALAPPDATA': r'C:\Users\张三\AppData\Local'},
        windows: true,
      ),
      r'C:\Users\张三\AppData\Local\Shepaw\bin\shepaw.exe',
    );
    expect(
      CliHost.installedBinaryFromEnv(const {}, windows: true),
      isNull,
    );
    expect(
      CliHost.debugBinaryCandidates(
        const {'HOME': '/Users/eden'},
        windows: false,
      ),
      [
        '/Users/eden/workspace/shepaw/shepaw-cli/target/debug/shepaw',
        '/Users/eden/workspace/shepaw/shepaw-cli/target/release/shepaw',
      ],
    );
  });
}
