import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/device_node/device_command_runner.dart';

Future<Map<String, dynamic>> succeed(String tool, Map<String, dynamic> args) async {
  return {'success': true, 'tool': tool, 'echo': args};
}

void main() {
  test('rejects invalid arguments before execution', () async {
    var ran = false;
    final runner = DeviceCommandRunner(
      execute: (tool, args) async {
        ran = true;
        return succeed(tool, args);
      },
    );
    final result = await runner.handle({
      'call_id': 'c1',
      'command': 'os.file.read',
      'args': <String, dynamic>{},
    });
    expect(ran, isFalse);
    expect(result['ok'], isFalse);
    expect(result['error']['code'], 'invalid_args');
  });

  test('critical commands stop for a local confirmation that is not available', () async {
    final runner = DeviceCommandRunner(execute: succeed);
    final result = await runner.handle({
      'call_id': 'c2',
      'command': 'os.process.kill',
      'args': {'pid': 42},
    });
    expect(result['ok'], isFalse);
    expect(result['error']['code'], 'device_permission_missing');
  });

  test('runs an allowed command and returns cmd.result', () async {
    final runner = DeviceCommandRunner(
      execute: (tool, args) async {
        expect(tool, 'file_read');
        expect(args['path'], '/tmp/a.txt');
        return {'success': true, 'content': 'hello'};
      },
    );
    final result = await runner.handle({
      'call_id': 'c3',
      'command': 'os.file.read',
      'args': {'path': '/tmp/a.txt'},
    });
    expect(result['type'], 'cmd.result');
    expect(result['ok'], isTrue);
    expect(result['data']['content'], 'hello');
  });

  test('turns a sandbox denial into forbidden', () async {
    final runner = DeviceCommandRunner(
      execute: (tool, args) async {
        return {
          'tool': tool,
          'args': args,
          'success': false,
          'sandbox_denied': true,
          'error': 'path is outside the sandbox',
        };
      },
    );
    final result = await runner.handle({
      'call_id': 'c4',
      'command': 'os.file.read',
      'args': {'path': '/etc/passwd'},
    });
    expect(result['error']['code'], 'forbidden');
  });
}
