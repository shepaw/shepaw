/// 用户
class User {
  final String id;
  final String username;
  final String avatar;
  final String status;

  User({
    required this.id,
    required this.username,
    required this.avatar,
    this.status = 'online',
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] ?? '',
      username: json['username'] ?? '',
      avatar: json['avatar'] ?? '👤',
      status: json['status'] ?? 'online',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'avatar': avatar,
      'status': status,
    };
  }
}
