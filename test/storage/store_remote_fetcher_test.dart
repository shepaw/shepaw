import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_remote_fetcher.dart';

void main() {
  Uint8List bytes(int n) => Uint8List.fromList(List<int>.generate(n, (i) => i % 256));

  test('空文件不发 read', () async {
    var fetches = 0;
    final out = BytesBuilder(copy: false);
    await StoreRemoteFetcher.pump(
      fileSize: 0,
      fetch: ({required offset, required length, required binary}) async {
        fetches++;
        throw StateError('should not fetch');
      },
      onChunk: out.add,
    );
    expect(fetches, 0);
    expect(out.takeBytes(), isEmpty);
  });

  test('二进制大块 + 窗口按 offset 重排', () async {
    final file = bytes(StoreTransfer.binaryChunk * 2 + 100);
    final offsets = <int>[];
    final started = <int, DateTime>{};
    final out = BytesBuilder(copy: false);

    await StoreRemoteFetcher.pump(
      fileSize: file.length,
      window: 2,
      fetch: ({required offset, required length, required binary}) async {
        expect(binary, isTrue);
        offsets.add(offset);
        started[offset] = DateTime.now();
        // 后发的第一块更早返回，验证重排。
        if (offset == StoreTransfer.binaryChunk) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final slice = file.sublist(offset, offset + length);
        return StoreReadChunk(
          bytes: slice,
          fileSize: file.length,
          eof: offset + length >= file.length,
          binary: true,
        );
      },
      onChunk: out.add,
    );

    expect(out.takeBytes(), file);
    expect(offsets.first, 0);
    expect(offsets.skip(1).toSet(), {
      StoreTransfer.binaryChunk,
      StoreTransfer.binaryChunk * 2,
    });
  });

  test('旧对端 bad_op 后回退 JSON 64KB', () async {
    final file = bytes(StoreTransfer.jsonChunk + 50);
    final lengths = <int>[];
    final encodings = <bool>[];
    final out = BytesBuilder(copy: false);

    await StoreRemoteFetcher.pump(
      fileSize: file.length,
      fetch: ({required offset, required length, required binary}) async {
        encodings.add(binary);
        lengths.add(length);
        if (binary && length > StoreTransfer.jsonChunk) {
          throw StoreException(StoreError.badOp, 'length too large');
        }
        final slice = file.sublist(offset, offset + length);
        return StoreReadChunk(
          bytes: slice,
          fileSize: file.length,
          eof: offset + length >= file.length,
        );
      },
      onChunk: out.add,
    );

    expect(out.takeBytes(), file);
    expect(encodings.first, isTrue);
    expect(encodings.skip(1), everyElement(isFalse));
    expect(lengths.skip(1), everyElement(lessThanOrEqualTo(StoreTransfer.jsonChunk)));
  });

  test('旧对端悄悄截成 64KB JSON 时按实收步进取后续块', () async {
    final file = bytes(StoreTransfer.jsonChunk * 2 + 10);
    final offsets = <int>[];
    final out = BytesBuilder(copy: false);

    await StoreRemoteFetcher.pump(
      fileSize: file.length,
      fetch: ({required offset, required length, required binary}) async {
        offsets.add(offset);
        final take = length > StoreTransfer.jsonChunk
            ? StoreTransfer.jsonChunk
            : length;
        final end = offset + take > file.length ? file.length : offset + take;
        final slice = file.sublist(offset, end);
        return StoreReadChunk(
          bytes: slice,
          fileSize: file.length,
          eof: end >= file.length,
        );
      },
      onChunk: out.add,
    );

    expect(out.takeBytes(), file);
    expect(offsets, [0, StoreTransfer.jsonChunk, StoreTransfer.jsonChunk * 2]);
  });
}
