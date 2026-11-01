import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/cli_bundle.dart';
import '../services/cli_host.dart';
import 'gate_entry.dart';

/// 准备本机主机的三个步骤。
enum HostInstallStep { install, start, connect }

enum HostStepState { pending, running, done, failed }

/// 每一步的结果。
class HostStepView {
  const HostStepView({required this.step, required this.state, this.note});

  final HostInstallStep step;
  final HostStepState state;

  /// 完成这一步时的附注，比如自带的版本号。
  final String? note;

  String get noteOrEmpty => note ?? '';
}

/// 准备本机主机：安装 → 启动 → 连接。
///
/// 回访时经常是「装了没跑」：那一次可以在 Splash 里原地跑完，用户只看到状态行
/// 变化，根本不进这页（超过 2 秒或失败才切过来，见 `GateNavigator`）。所以
/// 这个 controller 要能在没有页面的情况下先跑起来，再把同一个实例交给页面。
class HostInstallController extends ChangeNotifier {
  HostInstallController({
    this.reason = HostInstallReason.firstInstall,
    CliHostInstaller? installer,
    this.log,
  }) : _installer = installer ?? const DefaultCliHostInstaller();

  final HostInstallReason reason;
  final CliHostInstaller _installer;
  final void Function(String message)? log;

  final Map<HostInstallStep, HostStepState> _states = {
    for (final step in HostInstallStep.values) step: HostStepState.pending,
  };
  final Map<HostInstallStep, String?> _notes = {};
  DateTime? _stepStartedAt;

  /// 失败的那一步。空表示还没失败过。
  HostInstallStep? failedStep;

  /// 失败原因，只进日志和「详情」。
  String? failureDetail;

  /// 失败时的日志末尾几行（启动那一步才有）。
  String? logTail;

  String? _bundledVersion;
  bool _started = false;

  List<HostStepView> get steps => [
        for (final step in HostInstallStep.values)
          HostStepView(
            step: step,
            state: _states[step]!,
            note: _notes[step],
          ),
      ];

  bool get busy =>
      _states.values.any((state) => state == HostStepState.running);

  bool get done =>
      _states.values.every((state) => state == HostStepState.done);

  /// 已经跑了多久（给「进行中」那一步显示秒数用）。
  Duration get elapsed {
    final started = _stepStartedAt;
    if (started == null) return Duration.zero;
    return DateTime.now().difference(started);
  }

  /// 已经启动过就不再重复跑：Splash 可能已经把这一步跑完了。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await runFrom(HostInstallStep.install);
  }

  /// 从失败的那一步继续，不从头再来。
  Future<void> retry() async {
    await runFrom(failedStep ?? HostInstallStep.install);
  }

  Future<void> runFrom(HostInstallStep from) async {
    failedStep = null;
    failureDetail = null;
    logTail = null;
    for (final step in HostInstallStep.values) {
      if (step.index >= from.index) {
        _states[step] = HostStepState.pending;
      }
    }
    notifyListeners();
    for (final step in HostInstallStep.values) {
      if (step.index < from.index) continue;
      if (!await _run(step)) return;
    }
  }

  Future<bool> _run(HostInstallStep step) async {
    _states[step] = HostStepState.running;
    _stepStartedAt = DateTime.now();
    _notes[step] = null;
    notifyListeners();
    try {
      switch (step) {
        case HostInstallStep.install:
          final version = await _installer.install();
          _bundledVersion = version;
          _notes[step] = version;
        case HostInstallStep.start:
          await _installer.start();
        case HostInstallStep.connect:
          await _installer.connect();
      }
      _states[step] = HostStepState.done;
      notifyListeners();
      return true;
    } on HostInstallException catch (error) {
      _states[step] = HostStepState.failed;
      failedStep = step;
      failureDetail = error.detail;
      logTail = error.logTail;
      log?.call('host install ${step.name} failed: ${error.detail}');
      notifyListeners();
      return false;
    } catch (error) {
      _states[step] = HostStepState.failed;
      failedStep = step;
      failureDetail = '$error';
      log?.call('host install ${step.name} failed: $error');
      notifyListeners();
      return false;
    }
  }

  /// 完成页 / 日志按钮用。
  String? get bundledVersion => _bundledVersion;
}

/// 准备失败。[detail] 进日志，[logTail] 是主机日志的末尾几行。
class HostInstallException implements Exception {
  const HostInstallException(this.detail, {this.logTail});

  final String detail;
  final String? logTail;

  @override
  String toString() => detail;
}

/// 真正干活的那层。抽出来是为了测试里换掉，不去动真机的 CLI。
abstract class CliHostInstaller {
  const CliHostInstaller();

  /// 返回自带的版本号（没有就 null）。
  Future<String?> install();
  Future<void> start();
  Future<void> connect();
}

class DefaultCliHostInstaller implements CliHostInstaller {
  const DefaultCliHostInstaller();

  @override
  Future<String?> install() async {
    final bundled = await CliBundle.sync();
    final binary = bundled.binary ?? await CliHost.resolveBinary();
    if (binary == null) {
      throw const HostInstallException('没有找到 shepaw，也没能装上');
    }
    // 版本号只在主机已经在跑时才拿得到（peer-state.json）；刚装上时为 null。
    return (await CliHost.detect())?.version.trim().isEmpty ?? true
        ? null
        : (await CliHost.detect())!.version.trim();
  }

  @override
  Future<void> start() async {
    final cli = await CliHost.detect();
    if (cli != null) return; // 已经在跑了
    final binary = await CliHost.resolveBinary();
    if (binary == null) {
      throw const HostInstallException('没有找到 shepaw');
    }
    try {
      await CliHost.start(binary);
    } catch (error) {
      throw HostInstallException('$error', logTail: await _tail());
    }
  }

  @override
  Future<void> connect() async {
    final cli = await CliHost.detect();
    if (cli == null) {
      throw const HostInstallException('主机没在跑');
    }
    try {
      await CliHost.attach(cli);
    } on HostUnresponsiveException {
      throw HostInstallException('主机启动了，但没有响应', logTail: await _tail());
    } catch (error) {
      throw HostInstallException('$error', logTail: await _tail());
    }
  }

  /// 主机日志的末尾几行，给失败时展开看。
  Future<String?> _tail() async {
    try {
      final file = CliHost.logFile();
      if (!file.existsSync()) return null;
      final lines = await file
          .readAsLines()
          .timeout(const Duration(seconds: 2))
          .catchError((Object _) => <String>[]);
      final tail = lines.length > 20 ? lines.sublist(lines.length - 20) : lines;
      return tail.join('\n');
    } catch (_) {
      return null;
    }
  }
}
