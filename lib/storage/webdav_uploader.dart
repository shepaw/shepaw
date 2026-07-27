import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// 最小 WebDAV 写端（MKCOL + PUT），供危险区手动导出（方案 §7.5 / §13）。
abstract class WebdavUploader {
  Future<void> ensureCollection(String remoteDir);
  Future<void> putBytes(String remotePath, List<int> bytes);
  Future<void> close();
}

/// 基于 Dio 的 Basic Auth WebDAV 客户端。
class DioWebdavUploader implements WebdavUploader {
  DioWebdavUploader({
    required String baseUrl,
    String username = '',
    String password = '',
    Dio? dio,
  })  : _base = _normalizeBase(baseUrl),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(minutes: 5),
              sendTimeout: const Duration(minutes: 5),
              validateStatus: (code) => code != null && code < 500,
              headers: {
                if (username.isNotEmpty || password.isNotEmpty)
                  'authorization':
                      'Basic ${base64Encode(utf8.encode('$username:$password'))}',
              },
            ));

  final String _base;
  final Dio _dio;

  static String _normalizeBase(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('WebDAV base URL is empty');
    }
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  String _url(String remotePath) {
    final rel = remotePath.replaceAll('\\', '/');
    final cleaned = rel.startsWith('/') ? rel : '/$rel';
    return '$_base$cleaned';
  }

  @override
  Future<void> ensureCollection(String remoteDir) async {
    final parts = remoteDir
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    var acc = '';
    for (final part in parts) {
      acc = '$acc/$part';
      final res = await _dio.request<void>(
        _url(acc),
        options: Options(method: 'MKCOL'),
      );
      // 201 created / 405 already exists / 301/302 redirect ok
      final code = res.statusCode ?? 0;
      if (code == 201 ||
          code == 405 ||
          code == 301 ||
          code == 302 ||
          code == 200 ||
          code == 204) {
        continue;
      }
      // Some servers return 409 when parent missing — we create parents in order.
      if (code == 409) continue;
      throw StateError('MKCOL $acc failed: HTTP $code');
    }
  }

  @override
  Future<void> putBytes(String remotePath, List<int> bytes) async {
    final parent = p.posix.dirname(remotePath.replaceAll('\\', '/'));
    if (parent.isNotEmpty && parent != '.') {
      await ensureCollection(parent);
    }
    final res = await _dio.put<void>(
      _url(remotePath),
      data: Uint8List.fromList(bytes),
      options: Options(
        headers: {
          Headers.contentLengthHeader: bytes.length,
          Headers.contentTypeHeader: 'application/octet-stream',
        },
      ),
    );
    final code = res.statusCode ?? 0;
    if (code != 201 && code != 204 && code != 200) {
      throw StateError('PUT $remotePath failed: HTTP $code');
    }
  }

  @override
  Future<void> close() async => _dio.close(force: true);
}

/// 内存假客户端（单测）。
class MemoryWebdavUploader implements WebdavUploader {
  final Set<String> collections = {};
  final Map<String, List<int>> files = {};

  @override
  Future<void> ensureCollection(String remoteDir) async {
    final norm = remoteDir.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    if (norm.isEmpty) return;
    final parts = norm.split('/');
    var acc = '';
    for (final part in parts) {
      acc = acc.isEmpty ? part : '$acc/$part';
      collections.add(acc);
    }
  }

  @override
  Future<void> putBytes(String remotePath, List<int> bytes) async {
    final norm =
        remotePath.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    final parent = p.posix.dirname(norm);
    if (parent.isNotEmpty && parent != '.') {
      await ensureCollection(parent);
    }
    files[norm] = List<int>.from(bytes);
  }

  @override
  Future<void> close() async {}
}
