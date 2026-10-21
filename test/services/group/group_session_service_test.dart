import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_session_service.dart';

/// 新建群会话后是否还需要补一次 update 的判断。
///
/// 新主机在 create 里就把 flow_mode / enable_stage_gate 写进返回群；旧主机忽略
/// 这两个字段。这里按返回群的值决定要不要多跑一趟往返——判错会导致开关丢失
/// （漏判）或每次新建都白跑一趟（误判）。
void main() {
  group('groupCreateAppliedSwitches', () {
    test('返回群已经带上要求的开关 → 不用补 update', () {
      expect(
        groupCreateAppliedSwitches(
          {'flow_mode': true, 'enable_stage_gate': true},
          flowMode: true,
          enableStageGate: true,
        ),
        isTrue,
      );
      expect(
        groupCreateAppliedSwitches(
          {'flow_mode': false, 'enable_stage_gate': false},
          flowMode: false,
          enableStageGate: false,
        ),
        isTrue,
      );
      expect(
        groupCreateAppliedSwitches(
          {'flow_mode': true, 'enable_stage_gate': false},
          flowMode: true,
          enableStageGate: false,
        ),
        isTrue,
      );
    });

    test('旧主机忽略字段、返回默认 false → 要求 true 时必须补 update', () {
      expect(
        groupCreateAppliedSwitches(
          {'flow_mode': false, 'enable_stage_gate': false},
          flowMode: true,
          enableStageGate: false,
        ),
        isFalse,
      );
      expect(
        groupCreateAppliedSwitches(
          {'flow_mode': false, 'enable_stage_gate': false},
          flowMode: false,
          enableStageGate: true,
        ),
        isFalse,
      );
      // 字段整个缺失（更老的回包）等同默认 false。
      expect(
        groupCreateAppliedSwitches(
          {'id': 'group_1'},
          flowMode: true,
          enableStageGate: true,
        ),
        isFalse,
      );
    });

    test('没有返回群 → 保持旧行为，补一次 update', () {
      expect(
        groupCreateAppliedSwitches(
          null,
          flowMode: false,
          enableStageGate: false,
        ),
        isFalse,
      );
    });
  });
}
