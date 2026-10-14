import 'dart:io';
import 'dart:typed_data';

import 'device_identity.dart';
import 'host_pouch_target.dart';
import 'local_store.dart';
import 'remote_read_service.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 主机连不上：权威副本读写不了，也不该在本机留一份。
///
/// UI 把它翻成「连不上这台主机」，不要当成普通保存失败。
class HostOfflineException implements Exception {
  const HostOfflineException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 储物袋里「权威在主机」的那份文档的读写面。
///
/// 玉简（`slips`）用它：主机目录 `<space>/<主机指纹>/` 是唯一权威，客户端直接
/// 读写那一份，本地只有 `RemoteReadService` 的读缓存。本机就是主机时
/// （[LocalHostPouchDocuments]）行为与以前的纯本地读写一致。
///
/// 不照抄 [StoreService.listDevice] / `StoreUriReader.read` 的服务端解析：
/// 那两处在属主离线时会回落到本机 master（客户端上就是自己），把本机那份空
/// 目录当成主机的，既读不到缓存也报不出「离线」。这里一律点名主机。
abstract class HostPouchDocuments {
  /// 权威副本所在设备（主机 Noise 指纹）。
  String get deviceId;

  /// 主机不在本机。
  bool get isRemote;

  /// 本机就是主机时的底层 store；远端形态为 null。
  ///
  /// 只有存量迁移（`JadeSlipRehome`）需要它：那件事要跨 device 目录搬文件，
  /// 不是「当前权威目录」的读写。
  LocalStore? get localStore;

  String uri(String space, String path);

  /// 列一层目录。主机不可达时抛 [HostOfflineException]。
  Future<List<StoreEntry>> list(String space, {String? prefix});

  /// 读一份文档。不存在返回 null；主机不可达且无缓存时抛 [HostOfflineException]。
  ///
  /// 若调用方刚通过 [list] 拿到该文件的 [knownHash] 与 [knownSize]，传入后可跳过
  /// 远端 `store.meta` 校验往返，直接比对本地缓存或按大小拉取。
  Future<Uint8List?> read(
    String space,
    String path, {
    String? knownHash,
    int? knownSize,
  });

  Future<void> writeBytes(String space, String path, Uint8List bytes);

  /// 从磁盘流式写入。返回字节数。
  Future<int> writeFile(String space, String path, File file);

  Future<void> delete(String space, String path, {bool folder = false});
}

/// 本机就是主机：直接读写本机磁盘上的 `<deviceId>/<space>/…`。
class LocalHostPouchDocuments implements HostPouchDocuments {
  LocalHostPouchDocuments({required LocalStore store, required this.deviceId})
      : _store = store;

  final LocalStore _store;

  @override
  final String deviceId;

  @override
  bool get isRemote => false;

  @override
  LocalStore? get localStore => _store;

  @override
  String uri(String space, String path) =>
      storeUriWithRef(space, deviceId, path);

  @override
  Future<List<StoreEntry>> list(String space, {String? prefix}) => _store.list(
        deviceId,
        space,
        prefix: prefix,
        limit: 1000,
        depth: 1,
        computeHash: false,
      );

  @override
  Future<Uint8List?> read(
    String space,
    String path, {
    String? knownHash,
    int? knownSize,
  }) async {
    const chunk = LocalStore.maxBinaryReadChunk;
    final pieces = <int>[];
    var offset = 0;
    try {
      while (true) {
        final (data, _, eof) =
            await _store.read(deviceId, space, path, offset, chunk);
        pieces.addAll(data);
        if (eof) break;
        offset += data.length;
        if (data.isEmpty) break;
      }
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      rethrow;
    }
    return Uint8List.fromList(pieces);
  }

  @override
  Future<void> writeBytes(String space, String path, Uint8List bytes) =>
      _store.putBytes(
        deviceId: deviceId,
        space: space,
        path: path,
        bytes: bytes,
      );

  @override
  Future<int> writeFile(String space, String path, File file) async {
    final put = await _store.putFile(
      deviceId: deviceId,
      space: space,
      path: path,
      file: file,
    );
    return put.size;
  }

  @override
  Future<void> delete(String space, String path, {bool folder = false}) async {
    if (!folder) {
      try {
        await _store.delete(deviceId, space, path);
      } on StoreException catch (e) {
        if (e.code != StoreError.notFound) rethrow;
      }
      return;
    }
    final entries = await list(space, prefix: path);
    for (final entry in entries) {
      if (entry.isDir || entry.path.isEmpty) continue;
      await delete(space, entry.path);
    }
  }
}

/// 主机在别处：读写经 peer 上的 `store.*` 帧。
class RemoteHostPouchDocuments implements HostPouchDocuments {
  RemoteHostPouchDocuments({required this.deviceId});

  @override
  final String deviceId;

  @override
  bool get isRemote => true;

  @override
  LocalStore? get localStore => null;

  @override
  String uri(String space, String path) =>
      storeUriWithRef(space, deviceId, path);

  @override
  Future<List<StoreEntry>> list(String space, {String? prefix}) async {
    await _requireOnline();
    try {
      return await StoreService.instance.listViaServer(
        serverDeviceId: deviceId,
        deviceId: deviceId,
        space: space,
        prefix: prefix,
        limit: 1000,
        depth: 1,
        // 主机 SQLite entries 表已存 sha256，computeHash: true 直接从列中读取，
        // 让后续批量读取免掉逐条 store.meta 往返。
        computeHash: true,
      );
    } on StoreException catch (e) {
      final host = _asHostError(e);
      if (host != null) throw host;
      rethrow;
    }
  }

  @override
  Future<Uint8List?> read(
    String space,
    String path, {
    String? knownHash,
    int? knownSize,
  }) async {
    try {
      final result = await RemoteReadService.instance.readVerified(
        serverDeviceId: deviceId,
        deviceId: deviceId,
        space: space,
        path: path,
        allowOwnerFallback: false,
        knownHash: knownHash,
        knownSize: knownSize,
      );
      return result.bytes;
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      final host = _asHostError(e);
      if (host != null) throw host;
      rethrow;
    } on StateError catch (e) {
      if (e.message == 'master_offline') {
        throw const HostOfflineException('主机离线，这份内容本机还没有缓存');
      }
      rethrow;
    }
  }

  @override
  Future<void> writeBytes(String space, String path, Uint8List bytes) async {
    await _requireOnline();
    try {
      await StoreService.instance.writeDeviceBytes(
        deviceId: deviceId,
        space: space,
        path: path,
        bytes: bytes,
      );
      await RemoteReadService.instance.primeCache(
        deviceId: deviceId,
        space: space,
        path: path,
        bytes: bytes,
      );
    } on StoreException catch (e) {
      final host = _asHostError(e);
      if (host != null) throw host;
      rethrow;
    }
  }

  @override
  Future<int> writeFile(String space, String path, File file) async {
    await _requireOnline();
    try {
      return await StoreService.instance.writeDeviceFile(
        deviceId: deviceId,
        space: space,
        path: path,
        file: file,
      );
    } on StoreException catch (e) {
      final host = _asHostError(e);
      if (host != null) throw host;
      rethrow;
    }
  }

  @override
  Future<void> delete(String space, String path, {bool folder = false}) async {
    await _requireOnline();
    try {
      await StoreService.instance.deleteDevicePath(
        deviceId: deviceId,
        space: space,
        path: path,
        folder: folder,
      );
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return;
      final host = _asHostError(e);
      if (host != null) throw host;
      rethrow;
    }
  }

  /// 先把「主机不在线」判掉，不等 `store.*` 帧的 60 秒超时。
  Future<void> _requireOnline() async {
    if (!await StoreService.instance.isDeviceOnline(deviceId)) {
      throw const HostOfflineException('连不上这台主机');
    }
  }

  HostOfflineException? _asHostError(StoreException e) {
    if (e.code == StoreError.masterOffline ||
        e.code == StoreError.notPaired) {
      return const HostOfflineException('连不上这台主机');
    }
    return null;
  }
}

/// 按当前登录的袋子决定权威在哪台设备。
class HostPouchDocumentsFactory {
  HostPouchDocumentsFactory._();

  /// 本机没登录（或登录的就是本机）→ 本机就是主机。
  static Future<HostPouchDocuments> resolve() async {
    final target = await HostPouchTarget.resolve();
    if (!target.isRemote) {
      return LocalHostPouchDocuments(
        store: await StoreService.instance.localStore(),
        deviceId: target.deviceId,
      );
    }
    final self = await DeviceIdentity.deviceId();
    if (target.deviceId == self) {
      return LocalHostPouchDocuments(
        store: await StoreService.instance.localStore(),
        deviceId: self,
      );
    }
    return RemoteHostPouchDocuments(deviceId: target.deviceId);
  }
}
