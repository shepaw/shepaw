import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/jade_slip.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'logger_service.dart';

/// 玉简业务服务：读写储物袋 `notes` 分区里的待办。
///
/// 权威副本在 [JadeSlip.deviceId] 目录；本机打开时会合并各设备（含镜像）
/// 同 id 的最新版本，便于手机记下、电脑上交给 Agent 执行。
class JadeSlipService {
  JadeSlipService._();
  static final JadeSlipService instance = JadeSlipService._();

  static const _tag = 'JadeSlip';
  static const _uuid = Uuid();

  final _log = LoggerService();
  final _changes = StreamController<void>.broadcast();

  /// 测试注入，避免走 StoreService / DeviceIdentity。
  @visibleForTesting
  LocalStore? debugStore;

  @visibleForTesting
  String? debugDeviceId;

  Stream<void> get changes => _changes.stream;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<LocalStore> _store() async {
    final injected = debugStore;
    if (injected != null) return injected;
    return StoreService.instance.localStore();
  }

  Future<String> _selfId() async {
    final injected = debugDeviceId;
    if (injected != null && injected.isNotEmpty) return injected;
    return DeviceIdentity.deviceId();
  }

  Future<List<String>> _deviceIds(LocalStore store) async {
    final ids = <String>[];
    if (!await store.root.exists()) return ids;
    await for (final entity in store.root.list()) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (isValidDeviceId(name)) ids.add(name);
    }
    ids.sort();
    return ids;
  }

  Future<Uint8List> _readAll(
    LocalStore store,
    String deviceId,
    String path,
  ) async {
    const chunk = LocalStore.maxBinaryReadChunk;
    final pieces = <int>[];
    var offset = 0;
    while (true) {
      final (data, _, eof) = await store.read(
        deviceId,
        StoreSpace.notes,
        path,
        offset,
        chunk,
      );
      pieces.addAll(data);
      if (eof) break;
      offset += data.length;
      if (data.isEmpty) break;
    }
    return Uint8List.fromList(pieces);
  }

  Future<JadeSlip?> _readSlip(
    LocalStore store,
    String deviceId,
    String path,
  ) async {
    try {
      final bytes = await _readAll(store, deviceId, path);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      final slip = JadeSlip.fromJson(
        decoded.cast<String, dynamic>(),
        deviceId: deviceId,
      );
      if (slip.id.isEmpty) return null;
      return slip;
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      _log.warning('read slip $deviceId/$path: $e', tag: _tag);
      return null;
    } catch (e) {
      _log.warning('parse slip $deviceId/$path: $e', tag: _tag);
      return null;
    }
  }

  Future<void> _writeSlip(LocalStore store, JadeSlip slip) async {
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(slip.toJson())),
    );
    await store.putBytes(
      deviceId: slip.deviceId,
      space: StoreSpace.notes,
      path: slip.relPath,
      bytes: bytes,
    );
  }

  /// 列出玉简。同 id 多设备副本只保留 updatedAt 最新的一条。
  Future<List<JadeSlip>> list({
    JadeSlipStatus? status,
    String? query,
    bool includeArchived = false,
  }) async {
    final store = await _store();
    final byId = <String, JadeSlip>{};
    for (final deviceId in await _deviceIds(store)) {
      final entries = await store.list(
        deviceId,
        StoreSpace.notes,
        prefix: 'slips/',
        computeHash: false,
      );
      for (final entry in entries) {
        if (entry.isDir || !entry.path.endsWith('.json')) continue;
        final parts = entry.path.split('/');
        if (parts.length != 2 || parts.first != 'slips') continue;
        final slip = await _readSlip(store, deviceId, entry.path);
        if (slip == null) continue;
        final existing = byId[slip.id];
        if (existing == null) {
          byId[slip.id] = slip;
        } else {
          byId[slip.id] = JadeSlip.mergeCopies(existing, slip);
        }
      }
    }
    var list = byId.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!includeArchived) {
      list = list.where((s) => s.status != JadeSlipStatus.archived).toList();
    }
    if (status != null) {
      list = list.where((s) => s.status == status).toList();
    }
    final q = query?.trim().toLowerCase() ?? '';
    if (q.isNotEmpty) {
      list = list.where((s) {
        if (s.title.toLowerCase().contains(q)) return true;
        if (s.body.toLowerCase().contains(q)) return true;
        return s.items.any((i) => i.text.toLowerCase().contains(q));
      }).toList();
    }
    return list;
  }

  Future<int> countOpen() async {
    final all = await list();
    return all.where((s) => s.isOpen).length;
  }

  Future<JadeSlip?> getById(String id) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return null;
    final all = await list(includeArchived: true);
    for (final slip in all) {
      if (slip.id == trimmed) return slip;
    }
    return null;
  }

  Future<List<JadeSlip>> childrenOf(String id) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return const [];
    final all = await list(includeArchived: true);
    return all.where((s) => s.parentId == trimmed).toList();
  }

  /// 把父简上的一项拆成一条子简。子简记住父简和来源事项。
  Future<JadeSlip> splitItem({
    required String id,
    required String itemId,
  }) async {
    final parent = await getById(id);
    if (parent == null) throw StateError('jade slip not found: $id');
    JadeSlipItem? item;
    for (final candidate in parent.items) {
      if (candidate.id == itemId) item = candidate;
    }
    if (item == null) throw StateError('jade slip item not found: $itemId');
    if (item.childSlipId.isNotEmpty) {
      final existing = await getById(item.childSlipId);
      if (existing != null) return existing;
    }
    final child = await create(
      title: item.text,
      parentId: parent.id,
      sourceItemId: item.id,
      assigneeAgentId: item.assigneeAgentId,
      assigneeAgentName: item.assigneeAgentName,
    );
    await _mapItem(
      parent.id,
      item.id,
      (current) => current.copyWith(childSlipId: child.id),
    );
    return child;
  }

  Future<JadeSlip> create({
    required String title,
    String body = '',
    String goal = '',
    String constraints = '',
    String doneWhen = '',
    List<JadeSlipItem>? items,
    JadeSlipPriority priority = JadeSlipPriority.none,
    String assigneeAgentId = '',
    String assigneeAgentName = '',
    int? dueAtMs,
    String sourceInstructionId = '',
    String parentId = '',
    String sourceItemId = '',
    List<String> tags = const [],
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      throw ArgumentError('jade slip title cannot be empty');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final parsed = JadeSlip.itemsFromMarkdown(body);
    final merged = <JadeSlipItem>[
      ...?items,
      ...parsed.where(
        (p) => !(items ?? const []).any((i) => i.text == p.text),
      ),
    ];
    final slip = JadeSlip(
      id: _uuid.v4(),
      title: trimmedTitle,
      body: body.trim(),
      goal: goal.trim(),
      constraints: constraints.trim(),
      doneWhen: doneWhen.trim(),
      items: merged,
      priority: priority,
      assigneeAgentId: assigneeAgentId.trim(),
      assigneeAgentName: assigneeAgentName.trim(),
      dueAtMs: dueAtMs,
      tags: tags,
      sourceInstructionId: sourceInstructionId.trim(),
      parentId: parentId.trim(),
      sourceItemId: sourceItemId.trim(),
      deviceId: await _selfId(),
      createdAt: now,
      updatedAt: now,
    ).withDerivedStatus();
    await _writeSlip(await _store(), slip);
    _notify();
    return slip;
  }

  Future<JadeSlip> update(JadeSlip next) async {
    if (next.title.trim().isEmpty) {
      throw ArgumentError('jade slip title cannot be empty');
    }
    final existing = await getById(next.id);
    final self = await _selfId();
    var deviceId = next.deviceId;
    if (deviceId.isEmpty) deviceId = existing?.deviceId ?? self;
    final store = await _store();
    final originExists = existing != null &&
        await Directory(
          p.join(store.root.path, existing.deviceId, StoreSpace.notes),
        ).exists();
    if (!originExists) deviceId = self;

    final slip = next
        .copyWith(
          title: next.title.trim(),
          deviceId: deviceId,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        )
        .withDerivedStatus();
    await _writeSlip(store, slip);
    _notify();
    return slip;
  }

  Future<JadeSlip> setItemDone({
    required String id,
    required String itemId,
    required bool done,
    String actorId = '',
    String actorName = '',
    String sessionId = '',
  }) async {
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final items = [
      for (final item in slip.items)
        if (item.id == itemId)
          item.copyWith(
            state: done ? JadeSlipItemState.submitted : JadeSlipItemState.open,
            blockedReason: '',
            actorId: actorId.isEmpty ? null : actorId,
            actorName: actorName.isEmpty ? null : actorName,
            sessionId: sessionId.isEmpty ? null : sessionId,
            updatedAt: now,
          )
        else
          item,
    ];
    if (items.every((e) => e.id != itemId)) {
      throw StateError('jade slip item not found: $itemId');
    }
    final changed = items.firstWhere((e) => e.id == itemId);
    return update(slip.copyWith(
      items: items,
      events: [
        ...slip.events,
        _event(
          kind: done ? 'submitted' : 'reopened',
          text: done ? '提交「${changed.text}」' : '重新打开「${changed.text}」',
          itemId: itemId,
          actorId: actorId,
          actorName: actorName,
        ),
      ],
    ));
  }

  Future<JadeSlip> _mapItem(
    String id,
    String itemId,
    JadeSlipItem Function(JadeSlipItem item) change, {
    JadeSlipEvent? event,
  }) async {
    final slip = await getById(id);
    if (slip == null) throw StateError('jade slip not found: $id');
    var found = false;
    final items = <JadeSlipItem>[];
    for (final item in slip.items) {
      if (item.id == itemId) {
        found = true;
        items.add(change(item));
      } else {
        items.add(item);
      }
    }
    if (!found) throw StateError('jade slip item not found: $itemId');
    return update(slip.copyWith(
      items: items,
      events: event == null ? slip.events : [...slip.events, event],
    ));
  }

  /// 人验收某一项。Agent 的勾选只表示已提交。
  Future<JadeSlip> acceptItem({
    required String id,
    required String itemId,
    String actorId = '',
    String actorName = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final slip = await _mapItem(
      id,
      itemId,
      (item) => item.copyWith(
        state: JadeSlipItemState.accepted,
        actorId: actorId,
        actorName: actorName,
        blockedReason: '',
        updatedAt: now,
      ),
      event: _event(
        kind: 'accepted',
        text: '验收通过',
        itemId: itemId,
        actorId: actorId,
        actorName: actorName,
      ),
    );
    await _rollupAcceptedChild(slip);
    return (await getById(id)) ?? slip;
  }

  /// 没有清单的子简整条验收。有清单时仍逐项验收。
  Future<JadeSlip> acceptWhole({
    required String id,
    String actorId = '',
    String actorName = '',
  }) async {
    final slip = await getById(id);
    if (slip == null) throw StateError('jade slip not found: $id');
    if (slip.items.isEmpty) {
      final done = await update(slip.copyWith(status: JadeSlipStatus.done));
      await _rollupAcceptedChild(done);
      return (await getById(id)) ?? done;
    }
    var current = slip;
    for (final item in slip.items) {
      if (item.state == JadeSlipItemState.submitted) {
        current = await acceptItem(
          id: id,
          itemId: item.id,
          actorId: actorId,
          actorName: actorName,
        );
      }
    }
    return current;
  }

  /// 子简验收通过后，父简上对应事项变为已提交，等人在父简上验收。
  Future<void> _rollupAcceptedChild(JadeSlip slip) async {
    if (slip.parentId.isEmpty || slip.sourceItemId.isEmpty) return;
    if (slip.status != JadeSlipStatus.done && !slip.allItemsDone) return;
    final parent = await getById(slip.parentId);
    if (parent == null) return;
    JadeSlipItem? item;
    for (final candidate in parent.items) {
      if (candidate.id == slip.sourceItemId) item = candidate;
    }
    if (item == null || item.state == JadeSlipItemState.accepted) return;
    if (item.state == JadeSlipItemState.submitted) return;
    await setItemDone(
      id: parent.id,
      itemId: item.id,
      done: true,
    );
  }

  /// 退回已提交的项，留下原因，状态回到 open。
  Future<JadeSlip> returnItem({
    required String id,
    required String itemId,
    required String reason,
    String actorId = '',
    String actorName = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final slip = await _mapItem(
      id,
      itemId,
      (item) => item.copyWith(
        state: JadeSlipItemState.open,
        actorId: actorId,
        actorName: actorName,
        blockedReason: reason.trim(),
        updatedAt: now,
      ),
      event: _event(
        kind: 'returned',
        text: reason.trim().isEmpty ? '退回' : '退回：${reason.trim()}',
        itemId: itemId,
        actorId: actorId,
        actorName: actorName,
      ),
    );
    if (reason.trim().isEmpty) return slip;
    return addComment(
      id: id,
      text: reason.trim(),
      authorId: actorId,
      authorName: actorName,
      itemId: itemId,
    );
  }

  Future<JadeSlip> blockItem({
    required String id,
    required String itemId,
    required String reason,
    String actorId = '',
    String actorName = '',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _mapItem(
      id,
      itemId,
      (item) => item.copyWith(
        state: JadeSlipItemState.blocked,
        actorId: actorId,
        actorName: actorName,
        blockedReason: reason.trim(),
        updatedAt: now,
      ),
    );
  }

  Future<JadeSlip> addEvidence({
    required String id,
    required String itemId,
    required String uri,
  }) {
    final ref = uri.trim();
    if (ref.isEmpty) throw ArgumentError('evidence uri cannot be empty');
    final now = DateTime.now().millisecondsSinceEpoch;
    return _mapItem(
      id,
      itemId,
      (item) => item.copyWith(
        evidence: [...item.evidence, ref],
        updatedAt: now,
      ),
      event: _event(
        kind: 'evidence',
        text: '附上证据 $ref',
        itemId: itemId,
      ),
    );
  }

  /// 把清单中的一项交给另一个 Agent。空 id 表示取消这项的协作指派。
  Future<JadeSlip> assignItem({
    required String id,
    required String itemId,
    required String assigneeAgentId,
    String assigneeAgentName = '',
  }) async {
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final agentId = assigneeAgentId.trim();
    final agentName = assigneeAgentName.trim();
    JadeSlipItem? previous;
    for (final item in slip.items) {
      if (item.id == itemId) previous = item;
    }
    final items = [
      for (final item in slip.items)
        if (item.id == itemId)
          item.copyWith(
            assigneeAgentId: agentId,
            assigneeAgentName: agentName,
            clearAssignee: agentId.isEmpty,
            updatedAt: now,
          )
        else
          item,
    ];
    if (previous == null) {
      throw StateError('jade slip item not found: $itemId');
    }
    final from = previous.assigneeAgentName.isEmpty
        ? previous.assigneeAgentId
        : previous.assigneeAgentName;
    final to = agentName.isEmpty ? agentId : agentName;
    final note = agentId.isEmpty
        ? '取消「${previous.text}」的协作指派'
        : '「${previous.text}」交给 $to${from.isEmpty ? '' : '（原 $from）'}';
    await update(slip.copyWith(
      items: items,
      events: [
        ...slip.events,
        _event(
          kind: 'assigned',
          text: note,
          itemId: itemId,
          actorId: agentId,
          actorName: to,
        ),
      ],
    ));
    return addComment(
      id: id,
      text: note,
      authorId: agentId.isEmpty ? 'user' : agentId,
      authorName: to,
      itemId: itemId,
    );
  }

  Future<JadeSlip> addItem({
    required String id,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('item text cannot be empty');
    }
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    final item = JadeSlipItem(id: JadeSlipItem.newId(), text: trimmed);
    return update(slip.copyWith(items: [...slip.items, item]));
  }

  Future<JadeSlip> updateItemText({
    required String id,
    required String itemId,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('item text cannot be empty');
    }
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    final items = [
      for (final item in slip.items)
        if (item.id == itemId) item.copyWith(text: trimmed) else item,
    ];
    if (items.every((e) => e.id != itemId)) {
      throw StateError('jade slip item not found: $itemId');
    }
    return update(slip.copyWith(items: items));
  }

  Future<JadeSlip> removeItem({
    required String id,
    required String itemId,
  }) async {
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    final items = [for (final item in slip.items) if (item.id != itemId) item];
    if (items.length == slip.items.length) {
      throw StateError('jade slip item not found: $itemId');
    }
    return update(slip.copyWith(
      items: items,
      removedItemIds: [...slip.removedItemIds, itemId],
    ));
  }

  /// 追加一条留言。作者由调用方给定（App 内是本机用户，CLI 是执行中的 Agent）。
  Future<JadeSlip> addComment({
    required String id,
    required String text,
    required String authorId,
    String authorName = '',
    String itemId = '',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('comment text cannot be empty');
    }
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    final comment = JadeSlipComment(
      id: JadeSlipComment.newId(),
      authorId: authorId,
      authorName: authorName.trim(),
      itemId: itemId.trim(),
      text: trimmed,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    return update(slip.copyWith(comments: [...slip.comments, comment]));
  }

  Future<JadeSlip> removeComment({
    required String id,
    required String commentId,
  }) async {
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    final remaining = [
      for (final c in slip.comments)
        if (c.id != commentId) c,
    ];
    if (remaining.length == slip.comments.length) {
      throw StateError('jade slip comment not found: $commentId');
    }
    return update(slip.copyWith(comments: remaining));
  }

  Future<JadeSlip> addAttachment({
    required String id,
    required File file,
    String? displayName,
  }) async {
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    if (!await file.exists()) {
      throw ArgumentError('attachment file not found: ${file.path}');
    }
    final attId = JadeSlipAttachment.newId();
    final name = (displayName ?? p.basename(file.path)).trim();
    final safe = _safeFileName(name.isEmpty ? attId : name);
    final rel = 'slips/${slip.id}/files/$attId-$safe';
    final store = await _store();
    final put = await store.putFile(
      deviceId: slip.deviceId,
      space: StoreSpace.notes,
      path: rel,
      file: file,
    );
    final att = JadeSlipAttachment(
      id: attId,
      name: name.isEmpty ? safe : name,
      path: rel,
      sizeBytes: put.size,
    );
    return update(slip.copyWith(attachments: [...slip.attachments, att]));
  }

  Future<JadeSlip> removeAttachment({
    required String id,
    required String attachmentId,
  }) async {
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    JadeSlipAttachment? found;
    final remaining = <JadeSlipAttachment>[];
    for (final att in slip.attachments) {
      if (att.id == attachmentId) {
        found = att;
      } else {
        remaining.add(att);
      }
    }
    if (found == null) {
      throw StateError('jade slip attachment not found: $attachmentId');
    }
    final store = await _store();
    try {
      await store.delete(slip.deviceId, StoreSpace.notes, found.path);
    } on StoreException catch (e) {
      if (e.code != StoreError.notFound) rethrow;
    }
    return update(slip.copyWith(attachments: remaining));
  }

  Future<JadeSlip> complete(String id) async {
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final items = [
      for (final item in slip.items)
        if (item.state == JadeSlipItemState.accepted)
          item
        else
          item.copyWith(
            state: JadeSlipItemState.submitted,
            blockedReason: '',
            updatedAt: now,
          ),
    ];
    return update(slip.copyWith(items: items));
  }

  Future<void> delete(String id) async {
    final slip = await getById(id);
    if (slip == null) return;
    final store = await _store();
    for (final att in slip.attachments) {
      try {
        await store.delete(slip.deviceId, StoreSpace.notes, att.path);
      } on StoreException catch (e) {
        if (e.code != StoreError.notFound) rethrow;
      }
    }
    try {
      await store.delete(slip.deviceId, StoreSpace.notes, slip.relPath);
    } on StoreException catch (e) {
      if (e.code != StoreError.notFound) rethrow;
    }
    _notify();
  }

  JadeSlipEvent _event({
    required String kind,
    required String text,
    String itemId = '',
    String actorId = '',
    String actorName = '',
  }) {
    return JadeSlipEvent(
      id: JadeSlipItem.newId(),
      kind: kind,
      actorId: actorId,
      actorName: actorName,
      itemId: itemId,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 本机 store:// URI，Agent 也可用 `shepaw store read`。
  Future<String> uriOf(JadeSlip slip) async {
    return storeUriWithRef(StoreSpace.notes, slip.deviceId, slip.relPath);
  }
}

String _safeFileName(String name) {
  final base = p.basename(name).trim();
  final cleaned = base.replaceAll(RegExp(r'[\\/:\0]+'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'file';
  return cleaned;
}
