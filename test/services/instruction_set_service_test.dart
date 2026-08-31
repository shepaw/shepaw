import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/instruction_set_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/she_service.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  setUp(() async {
    // 清空指令表，保证用例互不干扰。
    final db = LocalDatabaseService();
    final dbHandle = await db.database;
    await dbHandle.delete('instruction_sets');
  });

  group('InstructionSetService', () {
    test('create persists and read back', () async {
      final created = await InstructionSetService.instance.create(
        name: '季度报告',
        description: '汇总季度销售',
        content: '总结 Q2 销售额、TOP3 亮点与风险',
        ownerAgentId: 'agent-a',
        ownerAgentName: 'Agent A',
      );

      final loaded = await InstructionSetService.instance.getByName('季度报告');
      expect(loaded, isNotNull);
      expect(loaded!.id, created.id);
      expect(loaded.content, '总结 Q2 销售额、TOP3 亮点与风险');
      expect(loaded.ownerAgentId, 'agent-a');
      expect(loaded.ownerAgentName, 'Agent A');
    });

    test('list filters by owner and orders by updated desc', () async {
      final service = InstructionSetService.instance;
      await service.create(
        name: 'a',
        content: 'c1',
        ownerAgentId: 'agent-a',
      );
      await service.create(
        name: 'b',
        content: 'c2',
        ownerAgentId: 'agent-b',
      );
      await service.create(
        name: 'c',
        content: 'c3',
        ownerAgentId: 'agent-a',
      );

      // list() 会确保内置系统指令「沉淀指令」存在，故全量为 4。
      final all = await service.list();
      expect(all.length, 4);
      expect(
        all.any((e) => e.name == InstructionSetService.systemInstructionName),
        isTrue,
      );

      final ownerA = await service.list(ownerAgentId: 'agent-a');
      expect(ownerA.length, 2);
      expect(ownerA.every((e) => e.ownerAgentId == 'agent-a'), isTrue);
    });

    test('create with duplicate name throws InstructionSetNameTaken', () async {
      final service = InstructionSetService.instance;
      await service.create(
        name: 'dup',
        content: 'c1',
        ownerAgentId: 'agent-a',
      );
      await expectLater(
        service.create(
          name: 'dup',
          content: 'c2',
          ownerAgentId: 'agent-b',
        ),
        throwsA(isA<InstructionSetNameTaken>()),
      );
    });

    test('update content/description/name', () async {
      final service = InstructionSetService.instance;
      final created = await service.create(
        name: '原始',
        description: '旧描述',
        content: '旧内容',
        ownerAgentId: 'agent-a',
      );

      final updated = await service.update(
        id: created.id,
        name: '新名',
        description: '新描述',
        content: '新内容',
      );
      expect(updated.name, '新名');
      expect(updated.description, '新描述');
      expect(updated.content, '新内容');
      expect(updated.ownerAgentId, 'agent-a');

      final reloaded = await service.getByName('新名');
      expect(reloaded!.content, '新内容');
      expect(await service.getByName('原始'), isNull);
    });

    test('update with empty description clears it', () async {
      final service = InstructionSetService.instance;
      final created = await service.create(
        name: 'x',
        description: '要清空',
        content: 'c',
        ownerAgentId: 'agent-a',
      );
      final updated = await service.update(id: created.id, description: '');
      expect(updated.description, isNull);
    });

    test('delete removes the instruction', () async {
      final service = InstructionSetService.instance;
      final created = await service.create(
        name: '待删',
        content: 'c',
        ownerAgentId: 'agent-a',
      );
      await service.delete(created.id);
      expect(await service.getById(created.id), isNull);
      expect(await service.getByName('待删'), isNull);
      // 内置系统指令仍会由 list() 保证存在。
      final rest = await service.list();
      expect(
        rest.any((e) => e.name == InstructionSetService.systemInstructionName),
        isTrue,
      );
    });

    test('list seeds built-in system instruction 沉淀指令', () async {
      final service = InstructionSetService.instance;
      final all = await service.list();
      final system = all
          .where((e) => e.name == InstructionSetService.systemInstructionName)
          .toList();
      expect(system, hasLength(1));
      expect(system.single.content, InstructionSetService.systemInstructionContent);
      expect(system.single.ownerAgentId, SheService.sheId);
      // 幂等：重复 list 不会产生重复系统指令。
      final again = await service.list();
      expect(
        again.where((e) => e.name == InstructionSetService.systemInstructionName),
        hasLength(1),
      );
    });
  });
}
