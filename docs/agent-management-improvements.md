# Agent 管理改进

## 问题描述

1. **Chat 列表出现无效的初始化 Agent**: 在首次启动时，系统会自动创建 2 个示例 Agent（GPT-4 助手和 Claude 助手），这些是不可用的假数据。

2. **添加 Agent 时没有测试连接**: 用户添加远端 Agent 时，系统直接保存配置而不测试连接是否可用，导致可能添加无效的 Agent 配置。

## 解决方案

### 1. 禁用示例数据初始化

**修改文件**: `lib/services/local_api_service.dart`

- **位置**: `initializeSampleData()` 方法 (行 494-569)
- **修改内容**: 移除了创建示例 Agent、Channel 和消息的代码
- **新行为**: 只输出日志提示用户手动添加 Agent，不再自动创建示例数据

```dart
/// 初始化示例数据（首次启动时）
Future<void> initializeSampleData() async {
  try {
    // 检查是否已有数据
    final existingAgents = await getAgents();
    if (existingAgents.isNotEmpty) {
      print('数据库已有数据，跳过初始化');
      return;
    }

    print('跳过示例数据初始化 - 请手动添加 Agent');
    // 不再创建示例 Agent，用户需要手动添加真实的远端 Agent
  } catch (e) {
    print('初始化示例数据失败: $e');
  }
}
```

### 2. 添加 Agent 连接测试

**修改文件**: `lib/screens/add_remote_agent_screen.dart`

- **位置**: `_connectToAgent()` 方法 (行 100-148)
- **修改内容**: 在保存 Agent 配置前，先测试连接健康状态
- **新流程**:
  1. 创建临时 Agent 配置
  2. 显示"测试连接"提示
  3. 调用健康检查 API（10 秒超时）
  4. 如果连接成功，保存并提示"连接成功"
  5. 如果连接失败，询问用户是否保留配置
     - 选择"删除配置": 删除 Agent
     - 选择"保留配置": 保存为离线状态

**关键代码**:
```dart
// 测试 Agent 连接
final isHealthy = await _agentService.checkAgentHealth(
  tempAgent.id,
  timeout: const Duration(seconds: 10),
);

if (isHealthy) {
  // 连接成功
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('连接成功！Agent 在线可用'),
      backgroundColor: Colors.green,
    ),
  );
  Navigator.pop(context, true);
} else {
  // 连接失败，询问是否保留
  final shouldKeep = await showDialog<bool>(...);
  // 根据用户选择处理
}
```

### 3. 添加清理示例数据功能

**修改文件**: `lib/screens/settings_screen.dart`

- **新增功能**: "Data Management" 部分
- **位置**: 在 "Account" 和 "About" 之间添加新节
- **功能**:
  - "Clear Sample Data" 选项
  - 自动识别并删除示例 Agent（名称为 "GPT-4 助手" 或 "Claude 助手"）
  - 级联删除相关的 Channel 和消息
  - 不会删除用户手动添加的远端 Agent

**新增代码**:
```dart
// Data management section
ListTile(
  leading: const Icon(Icons.delete_sweep, color: Colors.orange),
  title: const Text('Clear Sample Data'),
  subtitle: const Text('Remove demo agents and channels'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => _showClearDataDialog(context),
),
```

## 使用指南

### 对于现有用户（已有示例数据）

1. 打开应用
2. 进入 **Settings** 界面
3. 找到 **Data Management** 部分
4. 点击 **Clear Sample Data**
5. 确认删除操作
6. 示例 Agent 将被清理

### 对于新用户（首次安装）

1. 打开应用后不会看到任何 Agent
2. 点击 **+** 按钮添加远端 Agent
3. 填写 Agent 信息和 Token
4. 系统会自动测试连接
5. 连接成功后 Agent 将显示为在线状态

### 添加 Agent 的最佳实践

1. **选择正确的模式**:
   - "连接远端 Agent": 连接到已存在的远端服务
   - "创建本地配置": 生成 Token 供远端使用

2. **填写完整信息**:
   - Agent 名称
   - Endpoint URL（完整的服务地址）
   - Token（连接模式必填）
   - 协议类型（A2A、ACP、自定义）
   - 连接类型（HTTP 或 WebSocket）

3. **等待连接测试**:
   - 系统会自动测试 Agent 健康状态
   - 测试超时时间为 10 秒
   - 如果失败，可以选择保留配置稍后修复

## 技术细节

### 健康检查机制

- **实现位置**: `lib/services/remote_agent_service.dart:checkAgentHealth()`
- **检查方式**:
  - HTTP 调用 Agent 的 `/health` 端点
  - 自动从 `/a2a/task` 转换为 `/health`
  - 添加认证头（如果有 Token）
- **超时处理**: 默认 5 秒，添加 Agent 时使用 10 秒
- **状态更新**: 成功后自动更新 Agent 为在线状态

### 数据清理逻辑

- **识别方式**: 通过 Agent 名称匹配（"GPT-4 助手"、"Claude 助手"）
- **级联删除**: 利用数据库外键约束自动删除相关数据
- **安全性**: 不会删除用户手动添加的 Agent

## 测试建议

1. **测试示例数据清理**:
   - 使用包含示例数据的数据库
   - 验证清理功能正确删除示例 Agent
   - 确认不影响手动添加的 Agent

2. **测试连接健康检查**:
   - 使用有效的 Agent 配置测试成功场景
   - 使用无效的 Endpoint 测试失败场景
   - 测试超时场景（模拟慢网络）
   - 验证用户可以选择保留或删除失败的配置

3. **测试新用户体验**:
   - 清空数据库
   - 重新安装应用
   - 验证不会创建示例数据
   - 手动添加 Agent 并测试连接

## 影响范围

- ✅ 新用户不会看到无效的示例 Agent
- ✅ 添加 Agent 时会验证连接可用性
- ✅ 现有用户可以清理示例数据
- ✅ 提升了 Agent 管理的可靠性
- ✅ 改善了用户体验

## 相关文件

- `lib/services/local_api_service.dart` - 移除示例数据初始化
- `lib/screens/add_remote_agent_screen.dart` - 添加连接测试
- `lib/screens/settings_screen.dart` - 添加清理功能
- `lib/services/remote_agent_service.dart` - 健康检查实现（已存在）
