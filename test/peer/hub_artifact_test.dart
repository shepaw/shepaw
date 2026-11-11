import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/services/hub_artifact.dart';
import 'package:shepaw/peer/services/peer_connection.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

const _runScope = 'flow:fl_1:instance:in_1:run:run_1';

Map<String, dynamic> _artifact({
  String id = 'art_1',
  String scope = _runScope,
  List<Map<String, dynamic>>? versions,
}) =>
    {
      'artifact_id': id,
      'title': '设计报告',
      'kind': 'report',
      'latest_version': 2,
      'scope': scope,
      'pouch_id': 'p1',
      'versions': versions ??
          [
            {
              'version': 1,
              'filename': 'report.md',
              'hash': 'h1',
              'size': 1024,
              'created_ms': 1700000000000,
              'uri': 'pouch://p1/$_runScope/artifacts/$id/v1/report.md',
            },
          ],
    };

void main() {
  test('artifact frames carry the command id, scope and request id', () {
    expect(
      HubArtifact.artifactListFrame(_runScope, runId: 'run_1', requestId: 'r'),
      {
        'type': 'pouch_artifact_list_req',
        'command': 'pouch.artifact_list',
        'request_id': 'r',
        'scope': _runScope,
        'run_id': 'run_1',
        'args': {'scope': _runScope, 'run_id': 'run_1'},
      },
    );
    expect(
      HubArtifact.artifactGetFrame('art_1',
          scope: _runScope, version: 2, requestId: 'g'),
      {
        'type': 'pouch_artifact_get_req',
        'command': 'pouch.artifact_get',
        'request_id': 'g',
        'artifact_id': 'art_1',
        'scope': _runScope,
        'version': 2,
        'args': {
          'artifact_id': 'art_1',
        },
      },
    );
  });

  test('artifact frame types are routed as control frames', () {
    for (final type in const [
      HubArtifact.listRequestType,
      HubArtifact.listResponseType,
      HubArtifact.getRequestType,
      HubArtifact.getResponseType,
      HubArtifact.artifactListCommand,
      HubArtifact.artifactGetCommand,
    ]) {
      expect(PeerConnection.isControlFrameType(type), isTrue, reason: type);
    }
  });

  test('old hosts and unknown fields degrade to empty lists', () {
    expect(HubArtifact.parseListResponse(null), isEmpty);
    expect(HubArtifact.parseListResponse(const {}), isEmpty);
    expect(
      HubArtifact.parseListResponse({
        'success': false,
        'artifacts': [_artifact()],
      }),
      isEmpty,
    );
    expect(
      HubArtifact.parseListResponse(const {
        'artifacts': 'not a list',
      }),
      isEmpty,
    );
    expect(
      HubArtifact.parseListResponse(const {
        'artifacts': [
          {'title': 'missing id'},
          17,
        ],
      }),
      isEmpty,
    );
    final junk = HubArtifact.parseListResponse({
      'artifacts': [
        {
          'artifact_id': 'art_1',
          'unknown': {'nested': true},
          'versions': [
            null,
            {'version': {}, 'size': []}
          ],
        },
      ],
    });
    expect(junk, hasLength(1));
    expect(junk.single.versions, isEmpty);
    expect(HubArtifact.parseGetResponse(null), isNull);
    expect(HubArtifact.parseGetResponse(const {'artifact': {}}), isNull);
  });

  test('list/get responses accept typed, nested and URI-derived fields', () {
    final list = HubArtifact.parseListResponse({
      'success': true,
      'data': {
        'artifacts': [_artifact()],
      },
    });
    expect(list.single.artifactId, 'art_1');
    expect(list.single.latestVersion, 2);
    expect(list.single.versions.single.filename, 'report.md');
    expect(list.single.versions.single.size, 1024);
    expect(list.single.versions.single.createdMs, 1700000000000);

    final fromPath = HubArtifact.parseListResponse({
      'artifacts': [
        _artifact(versions: [
          {
            'version': '3',
            'path': 'artifacts/art_1/v3/final.txt',
            'scope': _runScope,
            'filename': 'final.txt',
          },
        ]),
      ],
    });
    expect(fromPath.single.versions.single.version, 3);
    expect(fromPath.single.versions.single.uri,
        'pouch://p1/$_runScope/artifacts/art_1/v3/final.txt');

    final got = HubArtifact.parseGetResponse({
      'ok': true,
      'artifact': _artifact(),
    });
    expect(got?.artifactId, 'art_1');
    expect(got?.versions, hasLength(1));
    // 主机命令目录的 artifact_get 直接把分组对象放在顶层 / data 里。
    final direct = HubArtifact.parseGetResponse({
      ..._artifact(),
      'success': true,
    });
    expect(direct?.artifactId, 'art_1');
    final enveloped = HubArtifact.parseGetResponse({
      'ok': true,
      'data': {..._artifact(), 'success': true},
    });
    expect(enveloped?.versions.single.filename, 'report.md');
  });

  test('grouping by artifact_id merges versions and keeps v<n> descending', () {
    final first = FlowArtifact.fromJson(_artifact(versions: [
      {
        'version': 1,
        'filename': 'draft.md',
        'uri': 'pouch://p1/$_runScope/artifacts/art_1/v1/draft.md',
      },
    ]));
    final second = FlowArtifact.fromJson(_artifact(
      scope: 'flow:fl_1:instance:in_1',
      versions: [
        {
          'version': 2,
          'filename': 'final.md',
          'uri':
              'pouch://p1/flow:fl_1:instance:in_1/artifacts/art_1/v2/final.md',
        },
      ],
    ));
    final grouped = FlowArtifact.groupByArtifactId([first, second]);
    expect(grouped, hasLength(1));
    expect(grouped.single.latestVersion, 2);
    expect(grouped.single.versions.map((v) => v.version), [2, 1]);
    expect(grouped.single.versions.map((v) => v.filename),
        ['final.md', 'draft.md']);
  });

  test('service round-trips list and get over injected control events',
      () async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubArtifact(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        if (frame['type'] == HubArtifact.listRequestType) {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': HubArtifact.listResponseType,
              'request_id': frame['request_id'],
              'success': true,
              'artifacts': [_artifact()],
            },
          ));
        } else if (frame['type'] == HubArtifact.getRequestType) {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': HubArtifact.getResponseType,
              'request_id': frame['request_id'],
              'ok': true,
              'artifact': _artifact(),
            },
          ));
        }
        return true;
      },
    );
    final listed = await client.list('p1', _runScope, runId: 'run_1');
    final got = await client.get('p1', 'art_1', scope: _runScope, version: 1);
    expect(listed.single.artifactId, 'art_1');
    expect(got?.artifactId, 'art_1');
    expect(sent.map((f) => f['type']), [
      HubArtifact.listRequestType,
      HubArtifact.getRequestType,
    ]);
    expect(await client.list('p1', ''), isEmpty);
    expect(sent, hasLength(2), reason: 'empty scope must not hit the host');
    await bus.close();
  });
}
