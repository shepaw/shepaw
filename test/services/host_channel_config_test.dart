import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/host_channel_config.dart';

void main() {
  test('proxy 地址拆出主机和 channel id', () {
    final parts = splitChannelAddress(
      'http://channel.shepaw.com/proxy/2b1fbbdb-1a48-4645-86c8-eca415b584ad',
    );
    expect(parts, isNotNull);
    expect(parts!.serverUrl, 'https://channel.shepaw.com');
    expect(parts.channelId, '2b1fbbdb-1a48-4645-86c8-eca415b584ad');
    expect(parts.ready, isTrue);
  });

  test('编号还没写完时先不拆', () {
    final parts = splitChannelAddress(
      'http://channel.shepaw.com/proxy/2b1fbbdb',
    );
    expect(parts!.ready, isFalse);
  });

  test('后面还有路径时编号算写完，并忽略 peer 路径', () {
    final parts = splitChannelAddress(
      'wss://channel.shepaw.com/proxy/ch_abc/peer/ws',
    );
    expect(parts!.serverUrl, 'https://channel.shepaw.com');
    expect(parts.channelId, 'ch_abc');
    expect(parts.ready, isTrue);
  });

  test('短名地址填别名', () {
    final parts = splitChannelAddress('https://channel.shepaw.com/c/home/peer/ws');
    expect(parts!.serverUrl, 'https://channel.shepaw.com');
    expect(parts.endpoint, 'home');
    expect(parts.channelId, isNull);
  });

  test('本机 http 地址不改成 https', () {
    final parts = splitChannelAddress(
      'http://127.0.0.1:8080/proxy/2b1fbbdb-1a48-4645-86c8-eca415b584ad/peer/ws',
    );
    expect(parts!.serverUrl, 'http://127.0.0.1:8080');
    expect(parts.ready, isTrue);
  });

  test('只有主机地址时不拆', () {
    expect(splitChannelAddress('https://channel.shepaw.com'), isNull);
  });
}
