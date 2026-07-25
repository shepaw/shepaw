import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/os/os_sandbox_config.dart';
import 'package:shepaw/clis/shepaw/os/os_sandbox_policy.dart';
import 'package:shepaw/clis/shepaw/os/os_shell_isolator.dart';

void main() {
  tearDown(() {
    OsSandboxConfig.resetActive();
  });

  group('OsSandboxConfig', () {
    test('defaults enable sandbox and include catastrophic patterns', () {
      expect(OsSandboxConfig.defaults.enabled, isTrue);
      expect(OsSandboxConfig.defaults.deniedSystemPathPrefixes, contains('/usr'));
      expect(
        OsSandboxConfig.defaults.deniedShellPatterns.any((p) => p.contains('sudo')),
        isTrue,
      );
      expect(
        OsSandboxConfig.defaults.deniedShellPatterns.any((p) => p.contains('rm -rf /')),
        isTrue,
      );
      // Ordinary rm must NOT be a default deny pattern by itself.
      expect(
        OsSandboxConfig.defaults.deniedShellPatterns.contains('rm '),
        isFalse,
      );
    });

    test('fromJson round-trips overrides', () {
      final cfg = OsSandboxConfig.fromJson({
        'enabled': false,
        'denied_shell_patterns': ['sudo', 'custom-deny'],
        'denied_system_path_prefixes': ['/opt/secret'],
        'extra_denied_roots': ['/tmp/blocked'],
      });
      expect(cfg.enabled, isFalse);
      expect(cfg.deniedShellPatterns, ['sudo', 'custom-deny']);
      expect(cfg.deniedSystemPathPrefixes, ['/opt/secret']);
      expect(cfg.extraDeniedRoots, ['/tmp/blocked']);

      final again = OsSandboxConfig.fromJson(cfg.toJson());
      expect(again.enabled, cfg.enabled);
      expect(again.deniedShellPatterns, cfg.deniedShellPatterns);
    });
  });

  group('OsSandboxPolicy', () {
    late OsSandboxPolicy policy;

    setUp(() {
      policy = OsSandboxPolicy(
        config: OsSandboxConfig.defaults,
        homeOverride: '/Users/test',
      );
    });

    test('allows file_delete under HOME', () {
      final d = policy.evaluate('file_delete', {
        'path': '/Users/test/Downloads/old.zip',
      });
      expect(d.allowed, isTrue);
    });

    test('denies file_write under /usr', () {
      final d = policy.evaluate('file_write', {'path': '/usr/bin/evil'});
      expect(d.allowed, isFalse);
      expect(d.reason, contains('protected path'));
    });

    test('denies file_delete under system path', () {
      final d = policy.evaluate('file_delete', {'path': '/etc/passwd'});
      expect(d.allowed, isFalse);
    });

    test('allows ordinary rm under HOME via shell', () {
      final d = policy.evaluateShell('rm /Users/test/Downloads/old.zip');
      expect(d.allowed, isTrue);
    });

    test('denies sudo', () {
      final d = policy.evaluateShell('sudo rm /Users/test/x');
      expect(d.allowed, isFalse);
      expect(d.reason, contains('sudo'));
    });

    test('denies rm -rf /', () {
      final d = policy.evaluateShell('rm -rf /');
      expect(d.allowed, isFalse);
    });

    test('denies mkfs', () {
      final d = policy.evaluateShell('mkfs.ext4 /dev/sda1');
      expect(d.allowed, isFalse);
    });

    test('denies redirect into /etc', () {
      final d = policy.evaluateShell('echo x > /etc/hosts');
      expect(d.allowed, isFalse);
    });

    test('allows when sandbox disabled', () {
      final open = OsSandboxPolicy(
        config: OsSandboxConfig.defaults.copyWith(enabled: false),
      );
      expect(
        open.evaluate('file_write', {'path': '/usr/bin/x'}).allowed,
        isTrue,
      );
      expect(open.evaluateShell('sudo ls').allowed, isTrue);
    });

    test('honours custom deniedShellPatterns', () {
      final custom = OsSandboxPolicy(
        config: OsSandboxConfig.defaults.copyWith(
          deniedShellPatterns: ['forbidden-tool'],
        ),
        homeOverride: '/Users/test',
      );
      expect(custom.evaluateShell('forbidden-tool --x').allowed, isFalse);
      expect(custom.evaluateShell('sudo ls').allowed, isTrue);
    });

    test('extraDeniedRoots blocks mutations', () {
      final custom = OsSandboxPolicy(
        config: OsSandboxConfig.defaults.copyWith(
          extraDeniedRoots: ['/Users/test/secret'],
        ),
        homeOverride: '/Users/test',
      );
      expect(
        custom
            .evaluate('file_delete', {'path': '/Users/test/secret/a.txt'})
            .allowed,
        isFalse,
      );
      expect(
        custom
            .evaluate('file_delete', {'path': '/Users/test/Downloads/a.txt'})
            .allowed,
        isTrue,
      );
    });
  });

  group('OsShellIsolator', () {
    test('buildBwrapArguments includes net unshare, home bind, and command', () {
      final args = OsShellIsolator.buildBwrapArguments(
        home: '/home/u',
        workingDir: '/home/u',
        command: 'echo hi',
        pathExists: (_) => true,
      );
      expect(args, contains('--die-with-parent'));
      expect(args, contains('--unshare-net'));
      expect(args, containsAllInOrder(['--bind', '/home/u', '/home/u']));
      expect(args, containsAllInOrder(['--ro-bind', '/usr', '/usr']));
      expect(args, containsAllInOrder(['--chdir', '/home/u']));
      expect(args.sublist(args.length - 3), ['/bin/sh', '-c', 'echo hi']);
    });

    test('buildMacSandboxProfile allows HOME writes', () {
      final profile =
          OsShellIsolator.buildMacSandboxProfile(home: '/Users/eden');
      expect(profile, contains('(version 1)'));
      expect(profile, contains('(subpath "/Users/eden")'));
      expect(profile, contains('(subpath "/System")'));
    });

    test('buildSandboxExecArguments wraps sh -c', () {
      final args = OsShellIsolator.buildSandboxExecArguments(
        profile: '(version 1)',
        command: 'ls',
      );
      expect(args, ['-p', '(version 1)', '/bin/sh', '-c', 'ls']);
    });

    test('resolve uses bwrap when fileExists reports it on Linux shape', () async {
      // Pure availability helpers
      expect(
        OsShellIsolator.isBwrapAvailable(fileExists: (p) => p.endsWith('bwrap')),
        isTrue,
      );
      expect(
        OsShellIsolator.isBwrapAvailable(fileExists: (_) => false),
        isFalse,
      );
      expect(
        OsShellIsolator.isSandboxExecAvailable(
          fileExists: (p) => p.contains('sandbox-exec'),
        ),
        isTrue,
      );
    });

    test('barePlan uses cmd on Windows shape via Platform — smoke', () {
      final plan = OsShellIsolator.barePlan(
        command: 'echo x',
        workingDirectory: '/tmp',
      );
      expect(plan.mode, 'none');
      expect(plan.arguments, contains('echo x'));
    });
  });
}
