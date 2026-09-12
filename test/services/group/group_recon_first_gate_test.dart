import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_orchestration_features.dart';
import 'package:shepaw/services/group/group_recon_first_gate.dart';

bool _bounce({
  String interactionType = 'form',
  bool membersConsulted = false,
  String? userContent,
  int bounceCount = 0,
}) {
  return GroupReconFirstGate.shouldBounce(
    isAdmin: true,
    interactionType: interactionType,
    hasDelegateableMembers: true,
    membersConsulted: membersConsulted,
    bounceCount: bounceCount,
    userContent: userContent,
  );
}

void main() {
  setUp(() {
    GroupOrchestrationFeatures.reconFirstBounce = true;
    GroupOrchestrationFeatures.maxReconFirstBounces = 1;
  });

  group('requirementLooksSettled', () {
    test('snake-style implement request is settled', () {
      expect(
        GroupReconFirstGate.requirementLooksSettled('帮我实现一个简版的 贪吃蛇小游戏'),
        isTrue,
      );
    });

    test('English implement request is settled', () {
      expect(
        GroupReconFirstGate.requirementLooksSettled('Please implement a snake game'),
        isTrue,
      );
    });

    test('form submit continuation is settled', () {
      expect(
        GroupReconFirstGate.requirementLooksSettled(
          '@She Form submitted: ① 交付形态: A',
        ),
        isTrue,
      );
    });

    test('strips trailing SYSTEM injection', () {
      expect(
        GroupReconFirstGate.requirementLooksSettled(
          '帮我写一个登录页\n\n[SYSTEM] 先摸底，再澄清：……',
        ),
        isTrue,
      );
    });

    test('fact-only question is not settled', () {
      expect(
        GroupReconFirstGate.requirementLooksSettled('袋子里有没有可复用的前端代码？'),
        isFalse,
      );
    });

    test('empty / greeting is not settled', () {
      expect(GroupReconFirstGate.requirementLooksSettled(''), isFalse);
      expect(GroupReconFirstGate.requirementLooksSettled('hi'), isFalse);
    });
  });

  group('shouldBounce', () {
    test('still bounces unclear first card', () {
      expect(_bounce(userContent: '这个群现在是什么情况'), isTrue);
    });

    test('skips bounce when the user already named a deliverable', () {
      expect(
        _bounce(userContent: '帮我实现一个简版的 贪吃蛇小游戏'),
        isFalse,
      );
    });

    test('still bounces when members were not consulted and ask is a fact', () {
      expect(_bounce(userContent: '看看现在做成什么样了'), isTrue);
    });
  });

  group('adminFirstTurnSystemNote', () {
    test('settled request tells admin not to recon the empty bag', () {
      final note = GroupReconFirstGate.adminFirstTurnSystemNote(
        '帮我实现一个简版的 贪吃蛇小游戏',
      );
      expect(note, contains('明确交付物'));
      expect(note, contains('不要为「袋子空不空」'));
      expect(note, isNot(contains('必须先用')));
    });

    test('unclear request keeps recon-first lecture', () {
      final note = GroupReconFirstGate.adminFirstTurnSystemNote('这个怎么弄？');
      expect(note, contains('先摸底，再澄清'));
      expect(note, contains('必须先用'));
    });
  });
}
