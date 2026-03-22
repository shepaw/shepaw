import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/config/app_config.dart';

void main() {
  group('AppConfig Tests', () {
    test('development环境配置正确', () {
      const config = AppConfig.development;
      
      expect(config.environment, 'development');
      expect(config.apiBaseUrl, 'http://localhost:3002');
      expect(config.wsBaseUrl, 'ws://localhost:3002');
      expect(config.enableLogging, true);
      expect(config.enableCrashReporting, false);
    });

    test('staging环境配置正确', () {
      const config = AppConfig.staging;
      
      expect(config.environment, 'staging');
      expect(config.apiBaseUrl, contains('staging'));
      expect(config.wsBaseUrl, contains('staging'));
      expect(config.enableLogging, true);
      expect(config.enableCrashReporting, true);
    });

    test('production环境配置正确', () {
      const config = AppConfig.production;
      
      expect(config.environment, 'production');
      expect(config.apiBaseUrl, isNot(contains('localhost')));
      expect(config.wsBaseUrl, isNot(contains('localhost')));
      expect(config.enableLogging, false);
      expect(config.enableCrashReporting, true);
    });

    test('toString输出格式正确', () {
      const config = AppConfig.development;
      final str = config.toString();
      
      expect(str, contains('development'));
      expect(str, contains('http://localhost:3002'));
    });
  });
}
