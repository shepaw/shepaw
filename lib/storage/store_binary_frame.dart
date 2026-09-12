import 'dart:convert';
import 'dart:typed_data';

/// Noise 明文里的 store 读块（替代 JSON `result.data` 里的 base64）。
///
/// ```
/// magic    4  "SPB1"
/// kind     1  0x01 = store_read_chunk
/// req_len  1
/// req_id   N  UTF-8
/// offset   8  BE
/// fileSize 8  BE
/// flags    1  bit0 = eof
/// data_len 4  BE
/// data     M
/// ```
class StoreBinaryChunk {
  StoreBinaryChunk({
    required this.reqId,
    required this.offset,
    required this.fileSize,
    required this.eof,
    required this.bytes,
  });

  static const magic = [0x53, 0x50, 0x42, 0x31]; // SPB1
  static const kindReadChunk = 1;
  static const maxReqIdBytes = 255;
  static const maxPayloadBytes = 1024 * 1024;

  final String reqId;
  final int offset;
  final int fileSize;
  final bool eof;
  final Uint8List bytes;

  static bool looksLike(Uint8List plain) {
    if (plain.length < 28) return false;
    return plain[0] == magic[0] &&
        plain[1] == magic[1] &&
        plain[2] == magic[2] &&
        plain[3] == magic[3];
  }

  Uint8List encode() {
    final req = utf8.encode(reqId);
    if (req.isEmpty || req.length > maxReqIdBytes) {
      throw ArgumentError('req_id length must be 1..$maxReqIdBytes');
    }
    if (bytes.length > maxPayloadBytes) {
      throw ArgumentError('chunk exceeds $maxPayloadBytes');
    }
    final out = Uint8List(27 + req.length + bytes.length);
    final bd = ByteData.sublistView(out);
    out[0] = magic[0];
    out[1] = magic[1];
    out[2] = magic[2];
    out[3] = magic[3];
    out[4] = kindReadChunk;
    out[5] = req.length;
    out.setRange(6, 6 + req.length, req);
    var o = 6 + req.length;
    bd.setUint64(o, offset, Endian.big);
    o += 8;
    bd.setUint64(o, fileSize, Endian.big);
    o += 8;
    out[o] = eof ? 1 : 0;
    o += 1;
    bd.setUint32(o, bytes.length, Endian.big);
    o += 4;
    out.setRange(o, o + bytes.length, bytes);
    return out;
  }

  static StoreBinaryChunk? tryDecode(Uint8List plain) {
    if (!looksLike(plain)) return null;
    try {
      return decode(plain);
    } on FormatException {
      return null;
    }
  }

  static StoreBinaryChunk decode(Uint8List plain) {
    if (!looksLike(plain)) {
      throw const FormatException('not a store binary frame');
    }
    final bd = ByteData.sublistView(plain);
    if (plain[4] != kindReadChunk) {
      throw FormatException('unknown store binary kind ${plain[4]}');
    }
    final reqLen = plain[5];
    if (reqLen < 1) {
      throw const FormatException('empty req_id');
    }
    var o = 6;
    if (o + reqLen + 8 + 8 + 1 + 4 > plain.length) {
      throw const FormatException('truncated store binary header');
    }
    final reqId = utf8.decode(plain.sublist(o, o + reqLen));
    o += reqLen;
    final offset = bd.getUint64(o, Endian.big);
    o += 8;
    final fileSize = bd.getUint64(o, Endian.big);
    o += 8;
    final eof = (plain[o] & 1) == 1;
    o += 1;
    final dataLen = bd.getUint32(o, Endian.big);
    o += 4;
    if (dataLen > maxPayloadBytes) {
      throw const FormatException('store binary payload too large');
    }
    if (o + dataLen != plain.length) {
      throw const FormatException('store binary payload length mismatch');
    }
    return StoreBinaryChunk(
      reqId: reqId,
      offset: offset,
      fileSize: fileSize,
      eof: eof,
      bytes: Uint8List.sublistView(plain, o, o + dataLen),
    );
  }
}
