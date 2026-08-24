import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/storage/store_file_visual.dart';
import 'package:shepaw/storage/store_protocol.dart';

/// 储物袋文件行可视分类：内部记账文件识别 / 归属段提取 / 友好标题。
void main() {
  final l10n = lookupAppLocalizations(const Locale('zh'));
  final sha = 'a' * 64;

  group('isInternalStoreFile', () {
    test('owner 根镜像与清单识别为内部文件', () {
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.runtime, 'agent_1/soul.md'),
          isTrue);
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.runtime, 'agent_1/memory.md'),
          isTrue);
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.runtime, 'agent_1/workspace.md'),
          isTrue);
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.runtime, 'agent_1/context.manifest.json'),
          isTrue);
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.cognition, 'agent_1/soul.md'),
          isTrue);
    });

    test('sessions 记录与归档识别为内部文件', () {
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.runtime, 'agent_1/ch_1/sessions/session.json'),
          isTrue);
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.runtime, 'agent_1/ch_1/sessions/archive-20260823.json'),
          isTrue);
    });

    test('群工作区元数据 / members / orchestration 识别为内部文件', () {
      expect(StoreFileVisual.isInternalStoreFile(StoreSpace.workspaces,
              'group_g1/group-workspace.json'),
          isTrue);
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.workspaces, 'group_g1/members/agent_2/notes.md'),
          isTrue);
      expect(
          StoreFileVisual.isInternalStoreFile(
              StoreSpace.workspaces,
              'group_g1/shared/orchestration/s1/round-0001/state.json'),
          isTrue);
      expect(
          StoreFileVisual.isInternalStoreFile(
              StoreSpace.workspaces,
              'group_g1/shared/orchestration/s1/round-0001/dispatch.json'),
          isTrue);
    });

    test('认知记忆记账 meta.json 识别为内部文件', () {
      // 用户报告路径：cognition/<device>/<agentId>/meta.json
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.cognition, 'she-builtin-agent-001/meta.json'),
          isTrue);
      // peer 子记忆记账
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.cognition, 'agent_1/peers/peer_2/meta.json'),
          isTrue);
      // legacy memory 空间同样覆盖
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.memory, 'agent_1/meta.json'),
          isTrue);
      // 其他空间的同名文件不受影响（用户实际文件）
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.files, 'docs/meta.json'),
          isFalse);
    });

    test('.keep 占位识别为内部文件', () {
      expect(StoreFileVisual.isInternalStoreFile(StoreSpace.files, 'docs/.keep'),
          isTrue);
    });

    test('用户可见文件不识别为内部文件', () {
      expect(
          StoreFileVisual.isInternalStoreFile(
              StoreSpace.runtime, 'agent_1/ch_1/attachments/$sha'),
          isFalse);
      expect(
          StoreFileVisual.isInternalStoreFile(
              StoreSpace.runtime, 'agent_1/ch_1/artifacts/task_1/report.md'),
          isFalse);
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.workspaces, 'agent_1/notes.md'),
          isFalse);
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.files, 'docs/plan.md'),
          isFalse);
      expect(StoreFileVisual.isInternalStoreFile(
              StoreSpace.files, 'chat/$sha'),
          isFalse);
    });
  });

  group('ownerSegmentOf', () {
    test('runtime / cognition / workspaces 取首段为 owner', () {
      expect(StoreFileVisual.ownerSegmentOf(
              StoreSpace.runtime, 'agent_1/ch_1/attachments/$sha'),
          'agent_1');
      expect(StoreFileVisual.ownerSegmentOf(
              StoreSpace.cognition, 'agent_1/soul.md'),
          'agent_1');
      expect(StoreFileVisual.ownerSegmentOf(
              StoreSpace.workspaces, 'group_g1/shared/orchestration/s1/state.json'),
          'group_g1');
    });

    test('files 等无归属分区返回 null', () {
      expect(StoreFileVisual.ownerSegmentOf(StoreSpace.files, 'docs/plan.md'),
          isNull);
      expect(StoreFileVisual.ownerSegmentOf(StoreSpace.files, ''), isNull);
    });
  });

  group('displayFriendlyName', () {
    test('已知内部文件映射为友好标题', () {
      expect(StoreFileVisual.displayFriendlyName(
              l10n, StoreSpace.runtime, 'agent_1/soul.md'),
          '灵魂设定');
      expect(StoreFileVisual.displayFriendlyName(
              l10n, StoreSpace.runtime, 'agent_1/memory.md'),
          '长期记忆');
      expect(StoreFileVisual.displayFriendlyName(
              l10n, StoreSpace.runtime, 'agent_1/workspace.md'),
          '工作区说明');
      expect(StoreFileVisual.displayFriendlyName(
              l10n, StoreSpace.runtime, 'agent_1/context.manifest.json'),
          '上下文清单');
      expect(StoreFileVisual.displayFriendlyName(
              l10n, StoreSpace.workspaces, 'group_g1/group-workspace.json'),
          '群工作区元数据');
      expect(StoreFileVisual.displayFriendlyName(
              l10n, StoreSpace.runtime, 'agent_1/ch_1/sessions/session.json'),
          '会话记录');
      expect(StoreFileVisual.displayFriendlyName(
              l10n, StoreSpace.runtime, 'agent_1/ch_1/sessions/archive-20260823.json'),
          '会话归档');
      expect(StoreFileVisual.displayFriendlyName(
              l10n,
              StoreSpace.workspaces,
              'group_g1/shared/orchestration/s1/round-0001/state.json'),
          '编排状态');
      expect(StoreFileVisual.displayFriendlyName(
              l10n,
              StoreSpace.workspaces,
              'group_g1/shared/orchestration/s1/round-0001/dispatch.json'),
          '任务分派');
    });

    test('普通文件保留原始名', () {
      expect(StoreFileVisual.displayFriendlyName(
              l10n, StoreSpace.files, 'docs/plan.md'),
          'plan.md');
    });

    test('聊天附件仍显示「聊天文件 · 短哈希」', () {
      final name = StoreFileVisual.displayFriendlyName(
          l10n, StoreSpace.runtime, 'agent_1/ch_1/attachments/$sha');
      expect(name, contains('聊天'));
      expect(name, contains('…'));
      expect(name, contains(sha.substring(0, 8)));
    });
  });
}
