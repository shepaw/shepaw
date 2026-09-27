/// 运行时浏览：把 `runtime/<owner>/…` 下的文件归到产物、附件、会话。
library;

import 'runtime_paths.dart';

enum RuntimeBucket { artifacts, attachments, sessions }

/// 运行时某个 owner 目录下的一个用户文件。
class RuntimePlacedFile {
  const RuntimePlacedFile({
    required this.path,
    required this.bucket,
    required this.channelId,
    this.workflowDir,
  });

  /// space 内相对路径。
  final String path;
  final RuntimeBucket bucket;

  /// `owner` 下的频道目录名。
  final String channelId;

  /// `wf_<id>__step_<id>`，没有工作流范围时为 null。
  final String? workflowDir;
}

const _buckets = <String, RuntimeBucket>{
  'artifacts': RuntimeBucket.artifacts,
  'attachments': RuntimeBucket.attachments,
  'sessions': RuntimeBucket.sessions,
};

/// 只认 [ownerId] 下面、落在三个目录之一的文件。
///
/// owner 根上的 soul / memory 镜像不归入任何一块。
RuntimePlacedFile? classifyRuntimeOwnerFile(String ownerId, String path) {
  final parts = path.split('/');
  if (parts.length < 4 || parts.first != ownerId) return null;
  final channelId = parts[1];
  if (channelId.isEmpty) return null;

  var bucketAt = -1;
  for (var i = 2; i < parts.length - 1; i++) {
    if (_buckets.containsKey(parts[i])) {
      bucketAt = i;
      break;
    }
  }
  if (bucketAt < 2) return null;

  String? workflowDir;
  if (bucketAt == 3 &&
      RuntimePaths.parseWorkflowScopeDir(parts[2]) != null) {
    workflowDir = parts[2];
  } else if (bucketAt != 2) {
    return null;
  }

  return RuntimePlacedFile(
    path: path,
    bucket: _buckets[parts[bucketAt]]!,
    channelId: channelId,
    workflowDir: workflowDir,
  );
}
