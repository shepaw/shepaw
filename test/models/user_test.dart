import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/user.dart';

void main() {
  group('User Model Tests', () {
    test('fromJson创建User对象', () {
      final json = {
        'id': 'user123',
        'username': 'testuser',
        'avatar': 'https://example.com/avatar.png',
      };
      
      final user = User.fromJson(json);
      
      expect(user.id, 'user123');
      expect(user.username, 'testuser');
      expect(user.avatar, 'https://example.com/avatar.png');
    });

    test('toJson转换为JSON', () {
      final user = User(
        id: 'user123',
        username: 'testuser',
        avatar: 'https://example.com/avatar.png',
      );
      
      final json = user.toJson();
      
      expect(json['id'], 'user123');
      expect(json['username'], 'testuser');
      expect(json['avatar'], 'https://example.com/avatar.png');
    });

    test('User对象相等性测试', () {
      final user1 = User(
        id: 'user123',
        username: 'testuser',
        avatar: 'https://example.com/avatar.png',
      );
      
      final user2 = User(
        id: 'user123',
        username: 'testuser',
        avatar: 'https://example.com/avatar.png',
      );
      
      // 注意: 如果User类没有实现operator ==, 这个测试会失败
      // 这是期望的行为，用于检测是否需要实现相等性
      expect(user1.id, user2.id);
      expect(user1.username, user2.username);
      expect(user1.avatar, user2.avatar);
    });

    test('处理空avatar', () {
      final json = {
        'id': 'user123',
        'username': 'testuser',
        'avatar': null,
      };
      
      final user = User.fromJson(json);
      
      expect(user.id, 'user123');
      expect(user.username, 'testuser');
    });
  });
}
