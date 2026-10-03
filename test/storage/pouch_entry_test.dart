import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/pouch_entry.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  PouchSession live({int expiresAtMs = 9000}) {
    return PouchSession(
      hubUrl: 'ws://127.0.0.1:18792/peer/ws',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: 'peer-1',
      token: 'login-token',
      sessionId: 'sid-1',
      expiresAtMs: expiresAtMs,
    );
  }

  test('没有登录态或已经过期时去选择页', () {
    expect(
      decidePouchEntry(
        session: null,
        nowMs: 10,
        isDesktop: false,
      ),
      PouchEntryDecision.choose,
    );
    expect(
      decidePouchEntry(
        session: live(expiresAtMs: 10),
        nowMs: 10,
        isDesktop: true,
        localCliFingerprint: 'fp',
        sessionHostFingerprint: 'fp',
      ),
      PouchEntryDecision.choose,
    );
  });

  test('电脑端只有本机 CLI 指纹对得上才恢复', () {
    expect(
      decidePouchEntry(
        session: live(),
        nowMs: 10,
        isDesktop: true,
        localCliFingerprint: 'fp',
        sessionHostFingerprint: 'fp',
      ),
      PouchEntryDecision.resume,
    );
    expect(
      decidePouchEntry(
        session: live(),
        nowMs: 10,
        isDesktop: true,
        localCliFingerprint: null,
        sessionHostFingerprint: 'fp',
      ),
      PouchEntryDecision.choose,
    );
    expect(
      decidePouchEntry(
        session: live(),
        nowMs: 10,
        isDesktop: true,
        localCliFingerprint: 'other',
        sessionHostFingerprint: 'fp',
      ),
      PouchEntryDecision.choose,
    );
  });

  test('手机端登录态有效就进主页，不看主机是否在线', () {
    expect(
      decidePouchEntry(
        session: live(),
        nowMs: 10,
        isDesktop: false,
        localCliFingerprint: null,
        sessionHostFingerprint: 'somewhere-else',
      ),
      PouchEntryDecision.resume,
    );
  });
}
