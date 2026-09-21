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
        if (existing == null || slip.updatedAt >= existing.updatedAt) {
          byId[slip.id] = slip;
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

  Future<JadeSlip> create({
    required String title,
    String body = '',
    List<JadeSlipItem>? items,
    JadeSlipPriority priority = JadeSlipPriority.none,
    String assigneeAgentId = '',
    String assigneeAgentName = '',
    int? dueAtMs,
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
      items: merged,
      priority: priority,
      assigneeAgentId: assigneeAgentId.trim(),
      assigneeAgentName: assigneeAgentName.trim(),
      dueAtMs: dueAtMs,
      tags: tags,
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
  }) async {
    final slip = await getById(id);
    if (slip == null) {
      throw StateError('jade slip not found: $id');
    }
    final items = [
      for (final item in slip.items)
        if (item.id == itemId) item.copyWith(done: done) else item,
    ];
    if (items.every((e) => e.id != itemId)) {
      throw StateError('jade slip item not found: $itemId');
    }
    return update(slip.copyWith(items: items));
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
    return update(slip.copyWith(items: items));
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
    final items = [for (final item in slip.items) item.copyWith(done: true)];
    return update(slip.copyWith(
      items: items,
      status: JadeSlipStatus.done,
    ));
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
