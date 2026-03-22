import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/acp_protocol.dart';

void main() {
  group('ACPRequest Tests', () {
    test('should create request with required fields', () {
      final req = ACPRequest(
        method: 'agent.chat',
        id: 1,
        params: {'message': 'Hello'},
      );

      expect(req.jsonrpc, '2.0');
      expect(req.method, 'agent.chat');
      expect(req.id, 1);
      expect(req.params, {'message': 'Hello'});
    });

    test('should create request without params', () {
      final req = ACPRequest(method: 'ping', id: 'req-1');

      expect(req.method, 'ping');
      expect(req.params, isNull);
      expect(req.id, 'req-1');
    });

    test('fromJson should parse correctly', () {
      final json = {
        'jsonrpc': '2.0',
        'method': 'agent.chat',
        'params': {'text': 'Hi'},
        'id': 42,
      };

      final req = ACPRequest.fromJson(json);

      expect(req.method, 'agent.chat');
      expect(req.params, {'text': 'Hi'});
      expect(req.id, 42);
    });

    test('fromJson should handle missing method', () {
      final req = ACPRequest.fromJson({'id': 1});
      expect(req.method, '');
    });

    test('toJson should produce valid JSON-RPC object', () {
      final req = ACPRequest(
        method: 'ping',
        id: 1,
        params: {'key': 'value'},
      );

      final json = req.toJson();

      expect(json['jsonrpc'], '2.0');
      expect(json['method'], 'ping');
      expect(json['id'], 1);
      expect(json['params'], {'key': 'value'});
    });

    test('toJson should omit params when null', () {
      final req = ACPRequest(method: 'ping', id: 1);
      final json = req.toJson();

      expect(json.containsKey('params'), false);
    });

    test('toJsonString should produce valid JSON string', () {
      final req = ACPRequest(method: 'ping', id: 1);
      final str = req.toJsonString();
      final decoded = jsonDecode(str);

      expect(decoded['method'], 'ping');
      expect(decoded['jsonrpc'], '2.0');
    });
  });

  group('ACPError Tests', () {
    test('should create error with required fields', () {
      final err = ACPError(code: -32600, message: 'Invalid Request');

      expect(err.code, -32600);
      expect(err.message, 'Invalid Request');
      expect(err.data, isNull);
    });

    test('should create error with data', () {
      final err = ACPError(
        code: -32603,
        message: 'Internal error',
        data: {'detail': 'stack trace'},
      );

      expect(err.data, {'detail': 'stack trace'});
    });

    test('fromJson should parse correctly', () {
      final json = {
        'code': -32601,
        'message': 'Method not found',
        'data': 'extra info',
      };

      final err = ACPError.fromJson(json);

      expect(err.code, -32601);
      expect(err.message, 'Method not found');
      expect(err.data, 'extra info');
    });

    test('fromJson should handle missing fields', () {
      final err = ACPError.fromJson({});

      expect(err.code, -1);
      expect(err.message, 'Unknown error');
    });

    test('toJson should produce correct output', () {
      final err = ACPError(code: -32000, message: 'Auth failed');
      final json = err.toJson();

      expect(json['code'], -32000);
      expect(json['message'], 'Auth failed');
      expect(json.containsKey('data'), false);
    });

    test('toJson should include data when present', () {
      final err = ACPError(code: -1, message: 'err', data: 'info');
      final json = err.toJson();

      expect(json['data'], 'info');
    });

    test('toString should format correctly', () {
      final err = ACPError(code: -32600, message: 'Bad request');
      expect(err.toString(), 'ACPError(-32600): Bad request');
    });
  });

  group('ACPResponse Tests', () {
    test('success factory should create response without error', () {
      final resp = ACPResponse.success(id: 1, result: {'ok': true});

      expect(resp.jsonrpc, '2.0');
      expect(resp.id, 1);
      expect(resp.result, {'ok': true});
      expect(resp.error, isNull);
      expect(resp.isSuccess, true);
      expect(resp.isError, false);
    });

    test('error factory should create response with error', () {
      final resp = ACPResponse.error(
        id: 1,
        code: -32601,
        message: 'Method not found',
        data: 'details',
      );

      expect(resp.id, 1);
      expect(resp.result, isNull);
      expect(resp.error, isNotNull);
      expect(resp.error!.code, -32601);
      expect(resp.error!.message, 'Method not found');
      expect(resp.error!.data, 'details');
      expect(resp.isSuccess, false);
      expect(resp.isError, true);
    });

    test('fromJson should parse success response', () {
      final json = {
        'jsonrpc': '2.0',
        'id': 42,
        'result': {'data': 'hello'},
      };

      final resp = ACPResponse.fromJson(json);

      expect(resp.id, 42);
      expect(resp.result, {'data': 'hello'});
      expect(resp.isSuccess, true);
    });

    test('fromJson should parse error response', () {
      final json = {
        'jsonrpc': '2.0',
        'id': 42,
        'error': {'code': -32600, 'message': 'Invalid Request'},
      };

      final resp = ACPResponse.fromJson(json);

      expect(resp.id, 42);
      expect(resp.isError, true);
      expect(resp.error!.code, -32600);
    });

    test('fromJsonString should parse JSON string', () {
      final jsonStr = '{"jsonrpc":"2.0","id":1,"result":"ok"}';
      final resp = ACPResponse.fromJsonString(jsonStr);

      expect(resp.id, 1);
      expect(resp.result, 'ok');
      expect(resp.isSuccess, true);
    });

    test('toJson should produce correct output for success', () {
      final resp = ACPResponse.success(id: 1, result: 'data');
      final json = resp.toJson();

      expect(json['jsonrpc'], '2.0');
      expect(json['id'], 1);
      expect(json['result'], 'data');
      expect(json.containsKey('error'), false);
    });

    test('toJson should produce correct output for error', () {
      final resp = ACPResponse.error(id: 1, code: -1, message: 'fail');
      final json = resp.toJson();

      expect(json['jsonrpc'], '2.0');
      expect(json['id'], 1);
      expect(json.containsKey('result'), false);
      expect(json['error']['code'], -1);
    });

    test('toJsonString should produce valid JSON', () {
      final resp = ACPResponse.success(id: 1, result: true);
      final decoded = jsonDecode(resp.toJsonString());

      expect(decoded['result'], true);
    });
  });

  group('ACPNotification Tests', () {
    test('should create notification without id', () {
      final notif = ACPNotification(
        method: 'ui.textContent',
        params: {'text': 'Hello'},
      );

      expect(notif.jsonrpc, '2.0');
      expect(notif.method, 'ui.textContent');
      expect(notif.params, {'text': 'Hello'});
    });

    test('should create notification without params', () {
      final notif = ACPNotification(method: 'task.completed');

      expect(notif.method, 'task.completed');
      expect(notif.params, isNull);
    });

    test('fromJson should parse correctly', () {
      final json = {
        'jsonrpc': '2.0',
        'method': 'task.started',
        'params': {'task_id': 'abc'},
      };

      final notif = ACPNotification.fromJson(json);

      expect(notif.method, 'task.started');
      expect(notif.params, {'task_id': 'abc'});
    });

    test('toJson should produce correct output', () {
      final notif = ACPNotification(
        method: 'ui.textContent',
        params: {'text': 'data'},
      );

      final json = notif.toJson();

      expect(json['jsonrpc'], '2.0');
      expect(json['method'], 'ui.textContent');
      expect(json['params'], {'text': 'data'});
      // Notification should not have 'id'
      expect(json.containsKey('id'), false);
    });

    test('toJson should omit params when null', () {
      final notif = ACPNotification(method: 'ping');
      final json = notif.toJson();

      expect(json.containsKey('params'), false);
    });

    test('toJsonString should produce valid JSON', () {
      final notif = ACPNotification(method: 'test');
      final decoded = jsonDecode(notif.toJsonString());

      expect(decoded['method'], 'test');
    });
  });

  group('ACPMethod Constants Tests', () {
    test('should have correct App -> Agent request methods', () {
      expect(ACPMethod.authAuthenticate, 'auth.authenticate');
      expect(ACPMethod.agentChat, 'agent.chat');
      expect(ACPMethod.agentCancelTask, 'agent.cancelTask');
      expect(ACPMethod.agentSubmitResponse, 'agent.submitResponse');
      expect(ACPMethod.agentRollback, 'agent.rollback');
      expect(ACPMethod.agentGetCard, 'agent.getCard');
      expect(ACPMethod.ping, 'ping');
    });

    test('should have correct Agent -> App UI notification methods', () {
      expect(ACPMethod.uiTextContent, 'ui.textContent');
      expect(ACPMethod.uiActionConfirmation, 'ui.actionConfirmation');
      expect(ACPMethod.uiSingleSelect, 'ui.singleSelect');
      expect(ACPMethod.uiMultiSelect, 'ui.multiSelect');
      expect(ACPMethod.uiFileUpload, 'ui.fileUpload');
      expect(ACPMethod.uiForm, 'ui.form');
      expect(ACPMethod.uiFileMessage, 'ui.fileMessage');
      expect(ACPMethod.uiMessageMetadata, 'ui.messageMetadata');
      expect(ACPMethod.uiRequestHistory, 'ui.requestHistory');
    });

    test('should have correct task lifecycle methods', () {
      expect(ACPMethod.taskStarted, 'task.started');
      expect(ACPMethod.taskCompleted, 'task.completed');
      expect(ACPMethod.taskError, 'task.error');
    });

    test('should have correct hub methods', () {
      expect(ACPMethod.hubGetSessions, 'hub.getSessions');
      expect(ACPMethod.hubGetSessionMessages, 'hub.getSessionMessages');
      expect(ACPMethod.hubGetAgentList, 'hub.getAgentList');
      expect(ACPMethod.hubGetHubInfo, 'hub.getHubInfo');
      expect(ACPMethod.hubSendFile, 'hub.sendFile');
      expect(ACPMethod.hubInitiateChat, 'hub.initiateChat');
    });
  });

  group('ACPErrorCode Constants Tests', () {
    test('should have correct JSON-RPC standard error codes', () {
      expect(ACPErrorCode.parseError, -32700);
      expect(ACPErrorCode.invalidRequest, -32600);
      expect(ACPErrorCode.methodNotFound, -32601);
      expect(ACPErrorCode.invalidParams, -32602);
      expect(ACPErrorCode.internalError, -32603);
    });

    test('should have correct application error codes', () {
      expect(ACPErrorCode.authenticationFailed, -32000);
      expect(ACPErrorCode.unauthorized, -32001);
      expect(ACPErrorCode.permissionDenied, -32002);
      expect(ACPErrorCode.notFound, -32003);
      expect(ACPErrorCode.pendingApproval, -32004);
      expect(ACPErrorCode.sessionNotFound, -32005);
      expect(ACPErrorCode.taskFailed, -32006);
      expect(ACPErrorCode.timeout, -32007);
      expect(ACPErrorCode.taskCancelled, -32008);
    });
  });
}
