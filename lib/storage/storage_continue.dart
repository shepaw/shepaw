import 'package:path/path.dart' as p;

import '../models/instruction_set.dart';
import '../models/jade_slip.dart';
import '../services/instruction_set_service.dart';
import '../services/jade_slip_service.dart';
import 'device_identity.dart';
import 'store_file_visual.dart';
import 'store_protocol.dart';
import 'store_service.dart';
import 'sync_engine.dart';
import 'sync_journal.dart';

/// 空间列表顶部「接着打开」的条数。
const storageContinueLimit = 5;

/// 跨空间继续打开会收录的分区。
///
/// 认知、工具、公开区不进这条短列表：它们按对象找，不按刚才改过什么找。
const storageContinueSpaces = <String>{
  StoreSpace.files,
  StoreSpace.slips,
  StoreSpace.instructions,
  StoreSpace.workspaces,
  StoreSpace.runtime,
  StoreSpace.artifacts,
};

/// 一条可以出现在「接着打开」里的变更。
class StorageContinueItem {
  const StorageContinueItem({
    required this.space,
    required this.path,
    required this.size,
    required this.mtimeMs,
    this.displayTitle,
    this.virtual = false,
    this.sha256 = '',
  });

  final String space;
  final String path;
  final int size;
  final int mtimeMs;
  final String? displayTitle;
  final bool virtual;
  final String sha256;

  String get key => '$space:$path';

  StorageContinueItem copyWith({String? displayTitle}) {
    return StorageContinueItem(
      space: space,
      path: path,
      size: size,
      mtimeMs: mtimeMs,
      displayTitle: displayTitle ?? this.displayTitle,
      virtual: virtual,
      sha256: sha256,
    );
  }
}

/// 变更日志里的一条是否值得出现在「接着打开」。
bool isStorageContinueCandidate(
  String space,
  String path, {
  required bool includeDedicatedRecords,
}) {
  if (!storageContinueSpaces.contains(space)) return false;
  if (path.isEmpty || p.basename(path) == '__folder__') return false;
  if (StoreFileVisual.isInternalStoreFile(space, path)) return false;
  final dedicated = (space == StoreSpace.slips && JadeSlip.isRecordPath(path)) ||
      (space == StoreSpace.instructions && InstructionSet.isRecordPath(path));
  if (!includeDedicatedRecords && dedicated) return false;
  return true;
}

/// 本机最近几条用户会再打开的文件。内部记账文件不出现。
Future<List<StorageContinueItem>> loadStorageContinueItems({
  bool includeDedicatedRecords = true,
  int limit = storageContinueLimit,
}) async {
  final self = await DeviceIdentity.deviceId();
  final existing = SyncEngine.instance.journal;
  final journal = existing ??
      SyncJournal(
        storeRoot: (await StoreService.instance.localStore()).root,
        ownerDeviceId: self,
      );
  final all = <StorageContinueItem>[];
  for (final item in await journal.recent()) {
    if (!isStorageContinueCandidate(
      item.space,
      item.path,
      includeDedicatedRecords: includeDedicatedRecords,
    )) {
      continue;
    }
    all.add(StorageContinueItem(
      space: item.space,
      path: item.path,
      size: item.size,
      mtimeMs: item.mtimeMs,
      sha256: item.sha256,
    ));
  }
  if (includeDedicatedRecords) {
    await _overlayInstructions(all);
  }
  await _applySlipTitles(all);
  await _applyInstructionTitles(all);
  all.removeWhere(
    (item) =>
        item.space == StoreSpace.instructions &&
        item.displayTitle == InstructionSetService.systemInstructionName,
  );
  all.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
  if (all.length > limit) return all.sublist(0, limit);
  return all;
}

Future<void> _overlayInstructions(List<StorageContinueItem> all) async {
  try {
    final items = await InstructionSetService.instance.list();
    final existing = {
      for (final f in all)
        if (f.space == StoreSpace.instructions) f.path,
    };
    for (final item in items) {
      if (item.name == InstructionSetService.systemInstructionName) continue;
      if (existing.contains(item.relPath)) continue;
      all.add(StorageContinueItem(
        space: StoreSpace.instructions,
        path: item.relPath,
        size: item.content.length,
        mtimeMs: item.updatedAt,
        displayTitle: item.name,
        virtual: true,
      ));
    }
  } catch (_) {}
}

Future<void> _applySlipTitles(List<StorageContinueItem> all) async {
  final need = all.any(
    (f) =>
        f.space == StoreSpace.slips &&
        JadeSlip.isRecordPath(f.path) &&
        (f.displayTitle == null || f.displayTitle!.isEmpty),
  );
  if (!need) return;
  try {
    final slips = await JadeSlipService.instance.list(includeArchived: true);
    final byPath = {for (final s in slips) s.relPath: s.title};
    for (var i = 0; i < all.length; i++) {
      final f = all[i];
      if (f.space != StoreSpace.slips || !JadeSlip.isRecordPath(f.path)) {
        continue;
      }
      if (f.displayTitle != null && f.displayTitle!.isNotEmpty) continue;
      final title = byPath[f.path];
      if (title == null || title.isEmpty) continue;
      all[i] = f.copyWith(displayTitle: title);
    }
  } catch (_) {}
}

Future<void> _applyInstructionTitles(List<StorageContinueItem> all) async {
  final need = all.any((f) => f.space == StoreSpace.instructions);
  if (!need) return;
  try {
    final items = await InstructionSetService.instance.list();
    final byPath = {for (final s in items) s.relPath: s.name};
    for (var i = 0; i < all.length; i++) {
      final f = all[i];
      if (f.space != StoreSpace.instructions) continue;
      if (f.displayTitle != null && f.displayTitle!.isNotEmpty) continue;
      final title = byPath[f.path];
      if (title == null || title.isEmpty) continue;
      all[i] = f.copyWith(displayTitle: title);
    }
  } catch (_) {}
}
