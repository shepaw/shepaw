import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/storage_continue.dart';
import 'package:shepaw/storage/store_protocol.dart';

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
}
