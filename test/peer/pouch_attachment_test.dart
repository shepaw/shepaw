import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/peer/pouch_attachment.dart';
import 'package:shepaw/peer/pouch_turn_relay.dart';

void main() {
  test('群附件落在群族目录，单聊落在 Agent 目录', () {
    final group = PouchAttachmentPlacement.resolve(
      placement: 'group',
      agentId: 'agent-a',
      channelId: 'channel-1',
      parentGroupId: 'family-9',
    );
    expect(group.ownerId, 'family-9');
    expect(group.channelId, 'channel-1');

    final dm = PouchAttachmentPlacement.resolve(
      placement: 'dm',
      agentId: 'agent-a',
      channelId: 'dm-1',
    );
    expect(dm.ownerId, 'agent-a');
    expect(dm.channelId, 'dm-1');
  });

  test('分片拼回原字节，领取时丢掉客户端自己的 store 地址', () async {
    final desk = PouchAttachmentDesk();
    expect(
      desk.begin(
        peerId: 'phone',
        fileId: 'file1234',
        fileName: 'a.png',
        mimeType: 'image/png',
        semanticType: 'image',
        size: 5,
        ownerId: 'agent-a',
        channelId: 'dm-1',
      ),
      isNull,
    );
    expect(
      desk.addChunk(
        peerId: 'phone',
        fileId: 'file1234',
        index: 1,
        bytes: Uint8List.fromList([4, 5]),
      ),
      isNull,
    );
    expect(
      desk.addChunk(
        peerId: 'phone',
        fileId: 'file1234',
        index: 0,
        bytes: Uint8List.fromList([1, 2, 3]),
      ),
      isNull,
    );

    Uint8List? stored;
    final done = await desk.finish(
      peerId: 'phone',
      fileId: 'file1234',
      chunkCount: 2,
      store: (bytes, {required ownerId, required channelId}) async {
        stored = Uint8List.fromList(bytes);
        expect(ownerId, 'agent-a');
        expect(channelId, 'dm-1');
        return 'pouch://runtime/0123456789abcdef/agent-a/dm-1/attachments/abc';
      },
    );
    expect(done.error, isNull);
    expect(stored, [1, 2, 3, 4, 5]);

    final taken = await desk.take(
      peerId: 'phone',
      raw: [
        {
          'file_id': 'file1234',
          'file_name': 'a.png',
          'mime_type': 'image/png',
          'size': 5,
          'type': 'image',
          'extra': {
            'pouch_uri': 'pouch://runtime/ffffffffffffffff/other/nope',
            'duration_ms': 12,
          },
        },
      ],
      read: (uri) async {
        expect(
          uri,
          'pouch://runtime/0123456789abcdef/agent-a/dm-1/attachments/abc',
        );
        return stored;
      },
    );
    expect(taken, hasLength(1));
    expect(taken!.single.bytes, [1, 2, 3, 4, 5]);
    expect(
      taken.single.extraMetadata!['pouch_uri'],
      'pouch://runtime/0123456789abcdef/agent-a/dm-1/attachments/abc',
    );
    expect(taken.single.extraMetadata!['duration_ms'], 12);

    expect(
      () => desk.take(
        peerId: 'phone',
        raw: [
          {'file_id': 'file1234'},
        ],
        read: (_) async => stored,
      ),
      throwsStateError,
    );
  });

  test('分片对不上或超过上限时不入库', () async {
    final desk = PouchAttachmentDesk();
    expect(
      desk.begin(
        peerId: 'phone',
        fileId: 'file1234',
        fileName: 'a.bin',
        mimeType: 'application/octet-stream',
        semanticType: 'file',
        size: AttachmentData.maxSizeBytes + 1,
        ownerId: 'agent-a',
        channelId: 'dm-1',
      ),
      isNotNull,
    );

    expect(
      desk.begin(
        peerId: 'phone',
        fileId: 'file5678',
        fileName: 'a.bin',
        mimeType: 'application/octet-stream',
        semanticType: 'file',
        size: 2,
        ownerId: 'agent-a',
        channelId: 'dm-1',
      ),
      isNull,
    );
    desk.addChunk(
      peerId: 'phone',
      fileId: 'file5678',
      index: 0,
      bytes: Uint8List.fromList([1]),
    );
    final done = await desk.finish(
      peerId: 'phone',
      fileId: 'file5678',
      chunkCount: 2,
      store: (bytes, {required ownerId, required channelId}) async {
        fail('不应写入');
      },
    );
    expect(done.error, isNotNull);
    expect(done.storeUri, isNull);
  });

  test('客户端按片送出，回合引用里不带字节', () async {
    final frames = <Map<String, dynamic>>[];
    late final PouchAttachmentClient client;
    client = PouchAttachmentClient(
      send: (peerId, frame) async {
        frames.add(frame);
        if (frame['type'] == PouchAttachment.beginType) {
          client.onAck({
            'file_id': frame['file_id'],
            'ok': true,
            'stage': 'begin',
          });
        }
        if (frame['type'] == PouchAttachment.endType) {
          client.onAck({
            'file_id': frame['file_id'],
            'ok': true,
            'stage': 'end',
            'pouch_uri':
                'pouch://runtime/0123456789abcdef/agent-a/dm-1/attachments/abc',
          });
        }
        return true;
      },
    );
    final payload = Uint8List.fromList(List<int>.generate(100, (i) => i));
    final attachment = AttachmentData(
      fileName: 'note.txt',
      mimeType: 'text/plain',
      sizeBytes: payload.length,
      bytes: payload,
      semanticType: 'document',
      extraMetadata: {
        'pouch_uri': 'pouch://runtime/ffffffffffffffff/client/local',
      },
    );
    final fileId = await client.push(
      peerId: 'host',
      attachment: attachment,
      agentId: 'agent-a',
      channelId: 'dm-1',
      placement: 'dm',
    );
    expect(frames.first['type'], PouchAttachment.beginType);
    expect(frames.first['placement'], 'dm');
    expect(frames.first['size'], 100);
    final chunk = frames[1];
    expect(chunk['type'], PouchAttachment.chunkType);
    expect(base64Decode(chunk['data'] as String), payload);
    expect(frames.last['chunk_count'], 1);

    late final PouchAttachmentClient rejected;
    rejected = PouchAttachmentClient(
      send: (peerId, frame) async {
        if (frame['type'] == PouchAttachment.beginType) {
          rejected.onAck({
            'file_id': frame['file_id'],
            'ok': false,
            'stage': 'begin',
            'error': '这台设备不是储物袋主机',
          });
        }
        return true;
      },
    );
    expect(
      rejected.push(
        peerId: 'host',
        attachment: attachment,
        agentId: 'agent-a',
        channelId: 'dm-1',
        placement: 'dm',
      ),
      throwsA(isA<StateError>()),
    );

    final ref = attachment.toPeerRefJson(fileId, stripClientStoreUri: true);
    expect(ref.containsKey('data'), isFalse);
    expect(ref['file_id'], fileId);
    expect(ref['extra'], isNull);
  });

  test('控制帧名单包含储物袋回合和附件', () {
    final source =
        File('lib/peer/services/peer_connection.dart').readAsStringSync();
    for (final type in [
      ...PouchTurnRelay.controlTypes,
      ...PouchAttachment.controlTypes,
    ]) {
      expect(source, contains("'$type'"), reason: type);
    }
  });
}
