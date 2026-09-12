import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/store_binary_frame.dart';

void main() {
  test('SPB1 编解码往返', () {
    final chunk = StoreBinaryChunk(
      reqId: 'r-abc',
      offset: 262144,
      fileSize: 1000000,
      eof: false,
      bytes: Uint8List.fromList(List<int>.generate(64, (i) => i)),
    );
    final raw = chunk.encode();
    expect(StoreBinaryChunk.looksLike(raw), isTrue);
    final decoded = StoreBinaryChunk.decode(raw);
    expect(decoded.reqId, 'r-abc');
    expect(decoded.offset, 262144);
    expect(decoded.fileSize, 1000000);
    expect(decoded.eof, isFalse);
    expect(decoded.bytes, chunk.bytes);
  });

  test('eof 标志与空块', () {
    final chunk = StoreBinaryChunk(
      reqId: 'r-1',
      offset: 10,
      fileSize: 10,
      eof: true,
      bytes: Uint8List(0),
    );
    final decoded = StoreBinaryChunk.decode(chunk.encode());
    expect(decoded.eof, isTrue);
    expect(decoded.bytes, isEmpty);
  });

  test('非 SPB1 / 截断拒绝', () {
    expect(StoreBinaryChunk.looksLike(Uint8List.fromList([1, 2, 3])), isFalse);
    expect(StoreBinaryChunk.tryDecode(Uint8List.fromList([1, 2, 3])), isNull);
    final good = StoreBinaryChunk(
      reqId: 'x',
      offset: 0,
      fileSize: 1,
      eof: true,
      bytes: Uint8List.fromList([9]),
    ).encode();
    expect(
      () => StoreBinaryChunk.decode(good.sublist(0, good.length - 1)),
      throwsFormatException,
    );
  });
}
