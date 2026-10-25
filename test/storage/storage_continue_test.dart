import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/storage/storage_continue.dart';
import 'package:shepaw/storage/store_protocol.dart';

JadeSlip _slip(String id, String title, {int updatedAt = 1000}) => JadeSlip(
      id: id,
      title: title,
      deviceId: 'device-1',
      createdAt: 1,
      updatedAt: updatedAt,
    );

void main() {
  test('接着打开只收用户会再打开的分区', () {
    expect(
      isStorageContinueCandidate(
        StoreSpace.files,
        'notes/today.md',
        includeDedicatedRecords: true,
      ),
      isTrue,
    );
    expect(
      isStorageContinueCandidate(
        StoreSpace.runtime,
        'agent-1/artifacts/out.md',
        includeDedicatedRecords: true,
      ),
      isTrue,
    );
    expect(
      isStorageContinueCandidate(
        StoreSpace.cognition,
        'agent-1/memory.md',
        includeDedicatedRecords: true,
      ),
      isFalse,
    );
    expect(
      isStorageContinueCandidate(
        StoreSpace.tools,
        'mcp/server.json',
        includeDedicatedRecords: true,
      ),
      isFalse,
    );
    expect(
      isStorageContinueCandidate(
        StoreSpace.public_,
        'shared.txt',
        includeDedicatedRecords: true,
      ),
      isFalse,
    );
  });

  test('内部占位和附件选择里的玉简正文不出现', () {
    expect(
      isStorageContinueCandidate(
        StoreSpace.files,
        'docs/.keep',
        includeDedicatedRecords: true,
      ),
      isFalse,
    );
    expect(
      isStorageContinueCandidate(
        StoreSpace.slips,
        'slip-1.json',
        includeDedicatedRecords: false,
      ),
      isFalse,
    );
    expect(
      isStorageContinueCandidate(
        StoreSpace.slips,
        'slip-1.json',
        includeDedicatedRecords: true,
      ),
      isTrue,
    );
    expect(
      isStorageContinueCandidate(
        StoreSpace.workspaces,
        'group/__folder__',
        includeDedicatedRecords: true,
      ),
      isFalse,
    );
  });

  test('v3 玉简补进接着打开：新的按 updatedAt 加入，旧的不重复', () {
    const legacy = StorageContinueItem(
      space: StoreSpace.slips,
      path: 'old.json',
      size: 12,
      mtimeMs: 900,
    );

    final added = slipContinueItems(
      [legacy],
      [
        _slip('old', '旧玉简', updatedAt: 800),
        _slip('new', '新玉简', updatedAt: 2000),
      ],
    );

    expect(added, hasLength(1));
    expect(added.single.space, StoreSpace.slips);
    expect(added.single.path, 'new.json');
    expect(added.single.displayTitle, '新玉简');
    expect(added.single.mtimeMs, 2000);
    expect(added.single.virtual, isTrue);
  });

  test('v3 玉简补进来时不动其他分区的条目', () {
    const file = StorageContinueItem(
      space: StoreSpace.files,
      path: 'docs/a.md',
      size: 3,
      mtimeMs: 10,
    );

    final added = slipContinueItems([file], [_slip('s1', '玉简')]);

    expect(added.map((e) => e.path), ['s1.json']);
  });
}
