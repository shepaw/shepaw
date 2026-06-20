/// 应用设备本地缓存策略（消息正文 LRU，不含全量附件）。
class AppCachePolicy {
  final int maxMessages;
  final int maxDays;
  final int maxBytes;
  final int maxBlobBytes;
  final bool wifiOnlyBlobs;

  const AppCachePolicy({
    this.maxMessages = 200,
    this.maxDays = 7,
    this.maxBytes = 100 * 1024 * 1024,
    this.maxBlobBytes = 50 * 1024 * 1024,
    this.wifiOnlyBlobs = false,
  });

  Map<String, dynamic> toJson() => {
        'maxMessages': maxMessages,
        'maxDays': maxDays,
        'maxBytes': maxBytes,
        'maxBlobBytes': maxBlobBytes,
        'wifiOnlyBlobs': wifiOnlyBlobs,
      };

  factory AppCachePolicy.fromJson(Map<String, dynamic> json) => AppCachePolicy(
        maxMessages: json['maxMessages'] as int? ?? 200,
        maxDays: json['maxDays'] as int? ?? 7,
        maxBytes: json['maxBytes'] as int? ?? 100 * 1024 * 1024,
        maxBlobBytes: json['maxBlobBytes'] as int? ?? 50 * 1024 * 1024,
        wifiOnlyBlobs: json['wifiOnlyBlobs'] as bool? ?? false,
      );
}
