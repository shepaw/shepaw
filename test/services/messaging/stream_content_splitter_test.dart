import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/messaging/stream_content_splitter.dart';

void main() {
  group('StreamContentSplitter', () {
    test('diverts collapsible chunks to progress, answer stays separate', () {
      final s = StreamContentSplitter();

      s.onMetadata({
        'collapsible': true,
        'collapsible_title': 'Thinking',
        'auto_collapse': true,
      });
      expect(s.onChunk('think...'), '');
      expect(s.progressContent, 'think...');
      expect(s.answerContent, '');

      s.onMetadata({'collapsible': false});
      expect(s.onChunk('Hello'), 'Hello');
      expect(s.answerContent, 'Hello');
      expect(s.progressContent, 'think...');

      final meta = s.finalProgressMetadata();
      expect(meta['progress_content'], 'think...');
      expect(meta['collapsible'], true);
      expect(meta['collapsible_title'], 'Thinking');
    });

    test('does not re-divert when upstream already split', () {
      final s = StreamContentSplitter();
      s.onMetadata({
        'progress_content': 'already folded',
        'collapsible': true,
        'collapsible_title': 'Tool',
      });
      expect(s.alreadySplitUpstream, true);
      expect(s.onChunk('Answer text'), 'Answer text');
      expect(s.progressContent, 'already folded');
      expect(s.answerContent, 'Answer text');
    });

    test('re-enters progress after more tool metadata', () {
      final s = StreamContentSplitter();
      s.onMetadata({'collapsible': true, 'collapsible_title': 'Run'});
      s.onChunk('[in_progress] Run\n');
      s.onMetadata({'collapsible': false});
      s.onChunk('partial answer ');
      s.onMetadata({'collapsible': true, 'collapsible_title': 'Read'});
      expect(s.onChunk('[completed] Read\n'), '');
      s.onMetadata({'collapsible': false});
      expect(s.onChunk('final'), 'final');

      expect(s.progressContent, contains('Run'));
      expect(s.progressContent, contains('Read'));
      expect(s.answerContent, 'partial answer final');
    });

    test('上游超长 progress 会被裁剪', () {
      final s = StreamContentSplitter();
      s.onMetadata({
        'progress_content': 'x' * 200000,
        'collapsible': true,
      });

      expect(s.progressContent.length, lessThan(40000));
      expect(s.progressContent, contains('中间省略'));
    });

    test('本地累积的 thinking 超过上限后裁剪', () {
      final s = StreamContentSplitter();
      s.onMetadata({'collapsible': true, 'collapsible_title': 'Thinking'});
      final chunk = 'y' * 1000;
      for (var i = 0; i < 100; i++) {
        s.onChunk(chunk);
      }

      // 追加了 100 KB，裁剪后应远小于它（两次裁剪之间允许回涨到高水位）。
      expect(s.progressContent.length, lessThan(80000));
      expect(s.progressContent, contains('中间省略'));
    });

    test('progressMetadataDelta is null until progress exists', () {
      final s = StreamContentSplitter();
      expect(s.progressMetadataDelta(), isNull);

      s.onMetadata({'collapsible': true});
      s.onChunk('x');
      final delta = s.progressMetadataDelta();
      expect(delta?['progress_content'], 'x');
      expect(delta?['collapsible_title'], 'Details');
      expect(delta?['auto_collapse'], isTrue);
    });

    test('respects auto_collapse false and custom title defaults', () {
      final s = StreamContentSplitter();
      final out = s.onMetadata({
        'collapsible': true,
        'auto_collapse': false,
      });
      expect(s.autoCollapse, isFalse);
      // Before any progress chunk arrives, collapsible is withheld so the
      // message bubble does not fold existing answer text into legacy whole-message collapse.
      expect(out.containsKey('collapsible'), isFalse);
      s.onChunk('tool');
      final meta = s.finalProgressMetadata();
      expect(meta['auto_collapse'], isFalse);
      expect(meta['collapsible_title'], 'Details');
    });

    test('records tool step into progress_content and withholds collapsible when Thinking is empty',
        () {
      final s = StreamContentSplitter();
      s.onChunk('First part of answer.');

      // 1. Thinking metadata with no thought chunks yet: progressContent stays
      // empty and collapsible is withheld so answer is not folded.
      final thinkingOut = s.onMetadata({
        'collapsible': true,
        'collapsible_title': 'Thinking',
        'auto_collapse': true,
      });
      expect(thinkingOut.containsKey('collapsible'), isFalse);
      expect(thinkingOut['collapsible_title'], 'Thinking');
      expect(s.progressContent, isEmpty);

      // 2. Tool metadata ('Edit') records a step line into progress_content so
      // silent tool calls are immediately visible in the progress block.
      final toolOut = s.onMetadata({
        'collapsible': true,
        'collapsible_title': 'Edit',
        'auto_collapse': true,
      });
      expect(toolOut['collapsible'], isTrue);
      expect(toolOut['collapsible_title'], 'Edit');
      expect(toolOut['progress_content'], '- Edit\n');
      expect(s.answerContent, 'First part of answer.');
    });

    test('collapsible false clears whole-message collapsible when no progress',
        () {
      final s = StreamContentSplitter();
      final out = s.onMetadata({'collapsible': false});
      expect(out['collapsible'], isFalse);
    });

    test('updates tool step line with terminal tool_status and renders plan entries',
        () {
      final s = StreamContentSplitter();
      s.onMetadata({
        'collapsible': true,
        'collapsible_title': 'Read file',
        'tool_status': 'in_progress',
      });
      expect(s.progressContent, '- Read file\n');

      s.onMetadata({
        'collapsible': true,
        'collapsible_title': 'Read file',
        'tool_status': 'completed',
      });
      expect(s.progressContent, '- Read file ✓\n');

      s.onMetadata({
        'collapsible': true,
        'collapsible_title': 'Plan',
        'plan': [
          {'content': 'Inspect schema', 'status': 'completed'},
          {'content': 'Patch handler', 'status': 'in_progress'},
          {'content': 'Run unit tests', 'status': 'pending'},
        ],
      });
      expect(
        s.progressContent,
        '- Read file ✓\n'
        '- [x] Inspect schema\n'
        '- [>] Patch handler\n'
        '- [ ] Run unit tests\n',
      );
      expect(s.progressTitle, 'Plan');
    });

    test('keeps host progress_steps and persists them with the final metadata',
        () {
      final s = StreamContentSplitter();
      final steps = [
        {'id': 't1', 'type': 'tool', 'title': 'Bash', 'status': 'running'},
      ];
      final out = s.onMetadata({
        'collapsible': true,
        'collapsible_title': 'Bash',
        'progress_content': 'Bash',
        'progress_steps': steps,
      });
      expect(out['progress_steps'], steps);

      // 后续帧不带步骤时（比如只有正文开始的信号），终态 metadata 仍留着最后一份。
      s.onMetadata({'collapsible': false});
      // 回合结束时仍标着进行中的步骤记为完成。
      final settled = s.finalProgressMetadata()['progress_steps'] as List;
      expect(settled.single['id'], 't1');
      expect(settled.single['status'], 'completed');
    });

    group('incremental progress_step_updates', () {
      Map<String, dynamic> think() => {
            'collapsible': true,
            'collapsible_title': 'Thinking',
            'progress_step_updates': [
              {
                'id': 'th-1',
                'type': 'thought',
                'title': 'Thinking',
                'status': 'running',
              },
            ],
          };

      test(
          'builds the list from updates and grows the thought body from chunks',
          () {
        final s = StreamContentSplitter();
        final out = s.onMetadata(think());
        expect(out.containsKey('progress_step_updates'), isFalse);
        expect((out['progress_steps'] as List).single['id'], 'th-1');

        s.onChunk('先看');
        s.onChunk('目录');
        final delta = s.progressMetadataDelta()!;
        expect((delta['progress_steps'] as List).single['body'], '先看目录');

        // 工具开始、思考收尾：按 id 合并，正文不丢。
        final out2 = s.onMetadata({
          'collapsible': true,
          'collapsible_title': 'Bash',
          'progress_step_updates': [
            {'id': 'th-1', 'status': 'completed', 'title': 'Thinking'},
            {'id': 't1', 'type': 'tool', 'title': 'Bash', 'status': 'running'},
          ],
        });
        final steps = out2['progress_steps'] as List;
        expect(steps, hasLength(2));
        expect(steps[0]['status'], 'completed');
        expect(steps[0]['body'], '先看目录');
        expect(steps[1]['id'], 't1');
      });

      test('published snapshots are never mutated afterwards', () {
        final s = StreamContentSplitter();
        s.onMetadata(think());
        s.onChunk('a');
        final first = s.progressMetadataDelta()!['progress_steps'] as List;
        s.onChunk('b');
        expect(first.single['body'], 'a');
      });

      test('running steps are settled in the final metadata', () {
        final s = StreamContentSplitter();
        s.onMetadata(think());
        final steps = s.finalProgressMetadata()['progress_steps'] as List;
        expect(steps.single['status'], 'completed');
      });

      test('a stream joined mid-turn falls back to the legacy rendering', () {
        final s = StreamContentSplitter();
        s.onMetadata({'collapsible': true, 'collapsible_title': 'Thinking'});
        s.onChunk('已经在想了');
        final out = s.onMetadata({
          'collapsible': true,
          'collapsible_title': 'Bash',
          'progress_step_updates': [
            {'id': 't1', 'type': 'tool', 'title': 'Bash', 'status': 'running'},
          ],
        });
        expect(out.containsKey('progress_steps'), isFalse);
        expect(
            s.progressMetadataDelta()!.containsKey('progress_steps'), isFalse);
        expect(
            s.finalProgressMetadata().containsKey('progress_steps'), isFalse);
      });

      test('a restored turn never shows a partial step list', () {
        final s = StreamContentSplitter()..stepsBroken = true;
        final out = s.onMetadata(think());
        expect(out.containsKey('progress_steps'), isFalse);
      });
    });
  });
}
