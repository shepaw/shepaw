import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

void main() {
  final steps = [
    {'id': 't1', 'type': 'tool', 'title': 'Bash', 'status': 'completed'},
  ];

  test('history replay carries progress_steps next to progress_content', () {
    final m = PeerHistoryMessage.fromJson({
      'role': 'agent',
      'content': '好了',
      'progress_content': 'Bash',
      'progress_title': 'Bash',
      'progress_steps': steps,
    })!;
    final meta = peerHistoryMessageMetadata(m)!;
    expect(meta['progress_steps'], steps);
    expect(meta['progress_content'], 'Bash');
  });

  test('old hubs without progress_steps still replay the legacy block', () {
    final m = PeerHistoryMessage.fromJson({
      'role': 'agent',
      'content': '好了',
      'progress_content': 'Bash',
    })!;
    expect(
        peerHistoryMessageMetadata(m)!.containsKey('progress_steps'), isFalse);
  });

  test('a later write without progress keeps the stored steps', () {
    final merged = metadataPreservingProgress(
      incoming: {'kind': 'x'},
      existingMetadataJson: jsonEncode({
        'progress_content': 'Bash',
        'progress_steps': steps,
      }),
    )!;
    expect(merged['progress_steps'], steps);
  });
}
