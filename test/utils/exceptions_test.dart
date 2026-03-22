import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/utils/exceptions.dart';

void main() {
  group('Exception Handler Tests', () {
    test('NetworkException创建正确', () {
      final exception = NetworkException('网络错误', code: 500);
      
      expect(exception.message, '网络错误');
      expect(exception.code, 500);
      expect(exception.toString(), '网络错误');
    });

    test('ApiException创建正确', () {
      final exception = ApiException('API错误', code: 404);
      
      expect(exception.message, 'API错误');
      expect(exception.code, 404);
    });

    test('AuthException创建正确', () {
      final exception = AuthException('认证失败', code: 401);
      
      expect(exception.message, '认证失败');
      expect(exception.code, 401);
    });

    test('handle方法处理AppException', () {
      final original = NetworkException('测试');
      final handled = ExceptionHandler.handle(original);
      
      expect(handled, same(original));
    });

    test('handle方法处理FormatException', () {
      final original = FormatException('格式错误');
      final handled = ExceptionHandler.handle(original);
      
      expect(handled, isA<ApiException>());
      expect(handled.message, contains('数据格式错误'));
    });

    test('handle方法处理通用Exception', () {
      final original = Exception('未知错误');
      final handled = ExceptionHandler.handle(original);
      
      expect(handled, isA<ApiException>());
      expect(handled.message, contains('未知错误'));
    });

    test('getUserMessage返回友好消息', () {
      final exception = NetworkException('网络连接失败');
      final message = ExceptionHandler.getUserMessage(exception);
      
      expect(message, '网络连接失败');
    });

    test('getUserMessage处理非AppException', () {
      final message = ExceptionHandler.getUserMessage(Exception('随机错误'));
      
      expect(message, '操作失败，请稍后重试');
    });

    test('ValidationException正确保存originalError', () {
      final original = FormatException('原始错误');
      final exception = ValidationException(
        '验证失败',
        originalError: original,
      );
      
      expect(exception.originalError, same(original));
    });
  });
}
