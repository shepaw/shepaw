import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/host_install_controller.dart';

class FakeInstaller implements CliHostInstaller {
  FakeInstaller({
    this.installError,
    this.startError,
    this.connectError,
    this.version = '0.9.3',
  });

  Object? installError;
  Object? startError;
  Object? connectError;
  final String? version;

  int installs = 0;
  int starts = 0;
  int connects = 0;

  @override
  Future<String?> install() async {
    installs++;
    final error = installError;
    if (error != null) throw error;
    return version;
  }

  @override
  Future<void> start() async {
    starts++;
    final error = startError;
    if (error != null) throw error;
  }

  @override
  Future<void> connect() async {
    connects++;
    final error = connectError;
    if (error != null) throw error;
  }
}

HostInstallController build(FakeInstaller fake) =>
    HostInstallController(installer: fake);

void main() {
  test('三步依次做完', () async {
    final fake = FakeInstaller();
    final controller = build(fake);
    await controller.start();
    expect(controller.done, isTrue);
    expect(controller.failedStep, isNull);
    expect(fake.installs, 1);
    expect(fake.starts, 1);
    expect(fake.connects, 1);
    expect(controller.bundledVersion, '0.9.3');
    controller.dispose();
  });

  test('启动失败时停在启动那一步', () async {
    final fake = FakeInstaller(
      startError: const HostInstallException('主机没有启动起来', logTail: 'boom'),
    );
    final controller = build(fake);
    await controller.start();
    expect(controller.done, isFalse);
    expect(controller.failedStep, HostInstallStep.start);
    expect(controller.failureDetail, '主机没有启动起来');
    expect(controller.logTail, 'boom');
    // 后面的步骤没有再跑。
    expect(fake.connects, 0);
    controller.dispose();
  });

  test('重试从失败的那一步继续，不从头再来', () async {
    final fake = FakeInstaller(
      startError: const HostInstallException('第一次失败'),
    );
    final controller = build(fake);
    await controller.start();
    expect(controller.failedStep, HostInstallStep.start);
    // 这回放它过。
    fake.startError = null;
    await controller.retry();
    expect(controller.done, isTrue);
    // 安装只跑过一次，重试没有从头开始。
    expect(fake.installs, 1);
    expect(fake.starts, 2);
    controller.dispose();
  });

  test('安装失败时后面两步都不跑', () async {
    final fake = FakeInstaller(
      installError: const HostInstallException('没能写入'),
    );
    final controller = build(fake);
    await controller.start();
    expect(controller.failedStep, HostInstallStep.install);
    expect(fake.starts, 0);
    expect(fake.connects, 0);
    controller.dispose();
  });

  test('start 只跑一次：Splash 可能已经开跑过', () async {
    final fake = FakeInstaller();
    final controller = build(fake);
    await controller.start();
    await controller.start();
    expect(fake.installs, 1);
    controller.dispose();
  });

  test('连接不上算失败，给「主机没有响应」', () async {
    final fake = FakeInstaller(
      connectError: const HostInstallException('主机启动了，但没有响应'),
    );
    final controller = build(fake);
    await controller.start();
    expect(controller.failedStep, HostInstallStep.connect);
    controller.dispose();
  });

  test('步骤视图会跟着状态变', () async {
    final fake = FakeInstaller();
    final controller = build(fake);
    expect(
      controller.steps.map((step) => step.state),
      [HostStepState.pending, HostStepState.pending, HostStepState.pending],
    );
    await controller.start();
    expect(
      controller.steps.map((step) => step.state),
      [HostStepState.done, HostStepState.done, HostStepState.done],
    );
    controller.dispose();
  });
}
