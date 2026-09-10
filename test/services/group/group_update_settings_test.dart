import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/group/group_management_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/she_service.dart';
import 'package:shepaw/services/tool_result_database_service.dart';

import '../../storage/test_harness.dart';

/// updateGroupSettings 服务层契约测试。
///
/// 核心守护点：更新是**整对象重建**（整行 replace），只改目标字段——
/// 未动字段（avatar / source_* / isPrivate / name / description）必须原样保留；
/// 文本空串与 `maxLoopRounds: 0` 必须能把列真正清成 null。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
    await ToolResultDatabaseService().database;
  });

  /// ChatService.notifyChannelUpdate 有 150ms 去抖 timer；等它结束避免跨用例
  /// 干扰，也让测试对实现细节不敏感。
  Future<void> settleNotify() =>
      Future<void>.delayed(const Duration(milliseconds: 200));

  group('updateGroupSettings 写回', () {
    test('admin 改 flowMode/enableStageGate/mentionMode/systemPrompt → DB 写回',
        () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final channelId = 'grp_$suffix';
      await _createAdminGroup(db, channelId, suffix);

      final service = GroupManagementService();
      final result = await service.updateGroupSettings(
        channelId: channelId,
        actorId: SheService.sheId,
        flowMode: true,
        enableStageGate: true,
        mentionMode: 'allMembers',
        systemPrompt: '  custom rules  ',
      );
      expect(result.ok, isTrue, reason: result.error);
      await settleNotify();

      final reloaded = await db.getChannelById(channelId);
      expect(reloaded!.flowMode, isTrue);
      expect(reloaded.enableStageGate, isTrue);
      expect(reloaded.mentionMode, 'allMembers');
      expect(reloaded.systemPrompt, 'custom rules',
          reason: '文本应 trim 后写入');
    });

    test("''/0 清除：systemPrompt:'' 与 maxLoopRounds:0 → 列 null", () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final channelId = 'grp_$suffix';
      await _createAdminGroup(db, channelId, suffix,
          systemPrompt: 'old', maxLoopRounds: 7);

      final service = GroupManagementService();
      final result = await service.updateGroupSettings(
        channelId: channelId,
        actorId: SheService.sheId,
        systemPrompt: '',
        maxLoopRounds: 0,
      );
      expect(result.ok, isTrue, reason: result.error);
      await settleNotify();

      final reloaded = await db.getChannelById(channelId);
      expect(reloaded!.systemPrompt, isNull);
      expect(reloaded.maxLoopRounds, isNull);
      expect(reloaded.effectiveMaxLoopRounds, 50);
    });

    test('未动字段 avatar/source_*/isPrivate/name 保持不变（防整行 replace 陷阱）',
        () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final channelId = 'grp_$suffix';
      await db.createChannel(
        Channel(
          id: channelId,
          name: 'Keep Name',
          type: 'group',
          members: [
            _member(SheService.sheId, role: 'admin'),
            _member('agent_$suffix'),
          ],
          description: 'keep desc',
          avatar: '/tmp/avatar.png',
          isPrivate: false,
          sourceSheChannelId: 'she_$suffix',
          maxLoopRounds: 12,
          mentionMode: 'adminOnly',
        ),
        'user',
      );

      final service = GroupManagementService();
      final result = await service.updateGroupSettings(
        channelId: channelId,
        actorId: SheService.sheId,
        flowMode: true,
      );
      expect(result.ok, isTrue, reason: result.error);
      await settleNotify();

      final reloaded = await db.getChannelById(channelId);
      expect(reloaded, isNotNull);
      expect(reloaded!.flowMode, isTrue, reason: '目标字段已更新');
      expect(reloaded.avatar, '/tmp/avatar.png',
          reason: 'avatar 不能被整行 replace 清空');
      expect(reloaded.sourceSheChannelId, 'she_$suffix');
      expect(reloaded.sourceGroupChannelId, isNull);
      expect(reloaded.isPrivate, isFalse);
      expect(reloaded.name, 'Keep Name');
      expect(reloaded.description, 'keep desc');
      expect(reloaded.maxLoopRounds, 12, reason: 'null=保留，未传不清空');
      expect(reloaded.mentionMode, 'adminOnly');
    });

    test('不在参数里的列（parentGroupId/createdBy）也原样保留', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final channelId = 'grp_$suffix';
      await db.createChannel(
        Channel(
          id: channelId,
          name: 'Keep Name',
          type: 'group',
          members: [
            _member(SheService.sheId, role: 'admin'),
            _member('agent_$suffix'),
          ],
          unreadCount: 3,
          parentGroupId: 'grp_parent_$suffix',
        ),
        'user',
      );

      final service = GroupManagementService();
      final result = await service.updateGroupSettings(
        channelId: channelId,
        actorId: SheService.sheId,
        enableStageGate: true,
      );
      expect(result.ok, isTrue, reason: result.error);
      await settleNotify();

      final reloaded = await db.getChannelById(channelId);
      expect(reloaded!.enableStageGate, isTrue);
      expect(reloaded.parentGroupId, 'grp_parent_$suffix',
          reason: 'updateGroupSettings 没有该参数，重建时必须搬移而不是丢弃');
      expect(reloaded.members.map((m) => m.id),
          containsAll([SheService.sheId, 'agent_$suffix']));
      expect(reloaded.isAdmin(SheService.sheId), isTrue);
    });

    test('name 与 description 也支持清空语义', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final channelId = 'grp_$suffix';
      await _createAdminGroup(db, channelId, suffix, description: 'desc');

      final service = GroupManagementService();
      final result = await service.updateGroupSettings(
        channelId: channelId,
        actorId: SheService.sheId,
        name: '  新名字  ',
        description: '   ',
      );
      expect(result.ok, isTrue, reason: result.error);
      await settleNotify();

      final reloaded = await db.getChannelById(channelId);
      expect(reloaded!.name, '新名字');
      expect(reloaded.description, isNull, reason: '空白 description = 清空');
    });

    test('非法 mentionMode → error 且 DB 不变', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final channelId = 'grp_$suffix';
      await _createAdminGroup(db, channelId, suffix);

      final service = GroupManagementService();
      final result = await service.updateGroupSettings(
        channelId: channelId,
        actorId: SheService.sheId,
        mentionMode: 'weird',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('Invalid mention mode'));
      await settleNotify();

      final reloaded = await db.getChannelById(channelId);
      expect(reloaded!.mentionMode, isNull,
          reason: '校验失败不应触碰 DB');
    });
  });

  group('updateGroupSettings 权限门控', () {
    test('非 admin 成员 → permission_denied', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final channelId = 'grp_$suffix';
      final nonAdminId = 'member_$suffix';
      await db.createChannel(
        Channel(
          id: channelId,
          name: 'Team',
          type: 'group',
          members: [
            _member('admin_$suffix', role: 'admin'),
            _member(nonAdminId),
          ],
        ),
        'user',
      );

      final service = GroupManagementService();
      final result = await service.updateGroupSettings(
        channelId: channelId,
        actorId: nonAdminId,
        flowMode: true,
      );
      expect(result.ok, isFalse);
      expect(result.toJson()['permission_denied'], isTrue);
      expect(result.error, contains('Permission denied'));
      await settleNotify();

      final reloaded = await db.getChannelById(channelId);
      expect(reloaded!.flowMode, isFalse, reason: '被拒后不应写入');
    });

    test('She 即使不是本群 admin 也有全量权限', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final channelId = 'grp_$suffix';
      await db.createChannel(
        Channel(
          id: channelId,
          name: 'Team',
          type: 'group',
          members: [_member('admin_$suffix', role: 'admin')],
        ),
        'user',
      );

      final service = GroupManagementService();
      final result = await service.updateGroupSettings(
        channelId: channelId,
        actorId: SheService.sheId,
        enableStageGate: true,
      );
      expect(result.ok, isTrue, reason: result.error);
      await settleNotify();

      final reloaded = await db.getChannelById(channelId);
      expect(reloaded!.enableStageGate, isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ChannelMember _member(String id, {String role = 'member'}) {
  return ChannelMember(
    id: id,
    type: 'agent',
    role: role,
    joinedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

/// 建一个 admin 为 She 的群（She 恒有全量权限），可带群配置初值。
Future<void> _createAdminGroup(
  LocalDatabaseService db,
  String channelId,
  int suffix, {
  String? description,
  String? systemPrompt,
  int? maxLoopRounds,
}) async {
  await db.createChannel(
    Channel(
      id: channelId,
      name: 'Team $suffix',
      type: 'group',
      members: [
        _member(SheService.sheId, role: 'admin'),
        _member('agent_$suffix'),
      ],
      description: description,
      systemPrompt: systemPrompt,
      maxLoopRounds: maxLoopRounds,
    ),
    'user',
  );
}
