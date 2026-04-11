# ShePaw 代码库快速参考指南

## 🎯 常见任务速查表

### 任务 1️⃣: 找"更多操作"菜单

#### 菜单类型 1: Chat 屏幕菜单 (右上角三点)
```
📍 位置: lib/screens/chat_screen.dart:1338-1362
🎨 控件: IconButton(icon: Icons.more_vert)
📝 菜单定义: lib/widgets/chat/chat_menu.dart
🔧 触发代码:
   if (c.isGroupMode) {
     ChatMenuHelper.showGroupMenu(...)
   } else {
     ChatMenuHelper.showAgentMenu(...)
   }
```

**DM 菜单项** (`chat_menu.dart:11-53`):
- ✅ 重置会话 (Icons.refresh)
- ✅ 查看详情 (Icons.info_outline)
- ✅ 自定义系统提示 (Icons.edit_note)
- ✅ 搜索消息 (Icons.search)

**Group 菜单项** (`chat_menu.dart:56-97`):
- ✅ 编辑群组信息 (Icons.edit)
- ✅ 查看群组成员 (Icons.group)
- ✅ 添加群组成员 (Icons.person_add)
- ✅ 搜索消息 (Icons.search)

---

#### 菜单类型 2: Agent 列表菜单 (列表项右侧三点)
```
📍 位置: lib/screens/agent_list_screen.dart:278-325
🎨 控件: PopupMenuButton<String>
📝 菜单项:
   - "发起对话" (Icons.chat)
   - "查看详情" (Icons.info_outline)
   - "删除" (Icons.delete_outline, 红色)
```

---

#### 菜单类型 3: Remote Agent 列表菜单
```
📍 位置: lib/screens/remote_agent_list_screen.dart:377-413
🎨 控件: PopupMenuButton<String>
📝 菜单项:
   - "查看 Token" (Icons.visibility)
   - "删除" (Icons.delete_outline, 红色)
```

---

### 任务 2️⃣: 找编辑功能入口

#### 编辑方式 1: Agent 详情页编辑按钮
```
📍 触发: lib/screens/agent_detail_screen.dart:123-128
🎨 控件: IconButton(icon: Icons.edit) 在 AppBar 右上角
💡 条件: !isNewAgent && !_isEditing
🔧 回调: setState(() => _isEditing = true)
```

**编辑模式开关** (`agent_detail_screen.dart:28`):
```dart
bool _isEditing = false;
```

**可编辑字段**:
- Agent 名称 (TextFormField, enabled: _isEditing)
- Agent 类型 (TextFormField, enabled: _isEditing)
- Agent 状态 (DropdownButtonFormField, enabled: _isEditing)
- Avatar URL (TextFormField, enabled: _isEditing)

**保存方法** (`agent_detail_screen.dart:41-108`):
```dart
Future<void> _saveAgent() async {
  // 验证表单
  // 调用 API
  // 更新 UI
  // 返回
}
```

---

#### 编辑方式 2: 群组从 Chat 菜单进入编辑
```
📍 触发: lib/screens/chat_screen.dart:1342-1348
🔧 菜单项: "编辑群组信息"
   → ChatMenuHelper.showGroupMenu()
   → onEditGroup: _editGroupInfo
   → GroupDetailScreen(startInEditMode: true)
📝 特点: 自动进入编辑模式 (_isEditing = true)
```

**群组编辑入口方法** (`group_detail_screen.dart:88-97`):
```dart
void _enterEditMode() {
  // 重置控制器
  _nameController.text = _channel.name;
  _descController.text = _channel.description ?? '';
  // ...
  setState(() => _isEditing = true);
}
```

---

### 任务 3️⃣: 找会话列表相关代码

#### DM 会话列表
```
📍 位置: lib/widgets/chat/session_list_panel.dart
🎨 组件: SessionListPanel (StatelessWidget)
         → _SessionListContent (StatefulWidget)
🎯 功能:
   - 显示与某 Agent 的所有会话
   - 支持创建新会话
   - 支持切换会话
   - 支持批量删除
💡 触发: Chat 屏幕右上角 Icons.history 按钮
```

**关键方法**:
- `_buildHeader()` - 显示会话列表头
- `_buildList()` - 渲染会话列表
- `_buildSessionTile()` - 单个会话项
- `_buildBottomBar()` - 批量删除按钮

---

#### Group 会话列表
```
📍 位置: lib/widgets/chat/group_session_list_panel.dart
🎨 组件: GroupSessionListPanel (StatelessWidget)
         → _GroupSessionListContent (StatefulWidget)
🎯 功能:
   - 显示群组的所有会话 (包括子会话)
   - 父会话不可删除
   - 支持创建新会话
   - 支持批量删除子会话
💡 触发: Chat 屏幕右上角 Icons.history 按钮 (Group 模式)
```

---

### 任务 4️⃣: 找 Chat 菜单处理代码

#### Chat 菜单触发点
```
📍 文件: lib/screens/chat_screen.dart
🔍 搜索: "Icons.more_vert" 或 "showAgentMenu" 或 "showGroupMenu"
📌 行号: 1338-1362
```

#### 菜单回调处理
```
📍 DM 模式菜单处理:
   onReset: () => _sendMessage('/reset')
   onViewDetails: () => _navigateToAgentDetail()
   onSearch: () => _showSearchDialog()
   onCustomSystemPrompt: () => _showDmSystemPromptDialog()

📍 Group 模式菜单处理:
   onEditGroup: () => _editGroupInfo()
   onShowMembers: () => _showGroupMembersPanel()
   onAddMember: () => _addGroupMember()
   onSearch: () => _showSearchDialog()
```

---

## 🔑 关键代码片段

### 代码段 1: 获取/设置编辑模式

```dart
// 获取当前编辑模式状态
bool isEditing = _isEditing;

// 进入编辑模式
setState(() => _isEditing = true);

// 退出编辑模式 (保留更改)
setState(() => _isEditing = false);

// 退出编辑模式 (放弃更改)
setState(() {
  _isEditing = false;
  // 恢复原始值
  _nameController.text = widget.agent!.name;
  // ...
});
```

---

### 代码段 2: 禁用/启用表单字段

```dart
// 表单字段跟随编辑模式
TextFormField(
  controller: _nameController,
  enabled: _isEditing,  // ← 关键
  // ...
)

// Dropdown 也一样
DropdownButtonFormField<String>(
  value: _selectedStatus,
  onChanged: _isEditing
      ? (value) { /* 处理更改 */ }
      : null,  // ← 禁用时传 null
)
```

---

### 代码段 3: 保存编辑后的数据

```dart
// Agent 编辑保存
Future<void> _saveAgent() async {
  if (!_formKey.currentState!.validate()) return;
  
  setState(() => _isLoading = true);
  try {
    if (widget.agent == null) {
      // 新建
      final newAgent = Agent(...);
      await _apiService.registerAgent(newAgent);
    } else {
      // 编辑
      final updatedAgent = Agent(...);
      await _apiService.updateAgent(updatedAgent);
    }
    setState(() => _isEditing = false);
  } finally {
    setState(() => _isLoading = false);
  }
}

// Group 编辑保存
Future<void> _saveEdit() async {
  // 验证
  final updated = Channel(
    id: _channel.id,
    name: _nameController.text.trim(),
    // ... 其他字段
  );
  await _databaseService.updateChannel(updated);
  
  if (widget.startInEditMode) {
    Navigator.pop(context, updated);  // 返回时传递更新的数据
  } else {
    setState(() {
      _channel = updated;
      _isEditing = false;
    });
  }
}
```

---

### 代码段 4: 菜单项回调示例

```dart
// 在 Chat 菜单中处理"编辑群组"
ChatMenuHelper.showGroupMenu(
  context,
  onEditGroup: _editGroupInfo,
  // ...
);

// _editGroupInfo 实现
void _editGroupInfo() {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => GroupDetailScreen(
        channel: _controller.groupChannel!,
        startInEditMode: true,  // 直接进入编辑模式
      ),
    ),
  ).then((updated) {
    if (updated != null) {
      // 群组信息已更新
      setState(() {
        _controller._groupChannel = updated;
      });
    }
  });
}
```

---

## 📂 文件快速定位

### 🔴 必读文件 (核心逻辑)

| 文件 | 用途 | 行号 |
|------|------|------|
| `chat_screen.dart` | Chat 主界面 + 菜单触发 | 1338-1362 |
| `chat_menu.dart` | 菜单定义 | 全文 |
| `agent_detail_screen.dart` | Agent 编辑 | 28, 41-108, 123-128 |
| `group_detail_screen.dart` | 群组编辑 | 34, 88-97, 103-150 |
| `session_list_panel.dart` | DM 会话列表 | 全文 |
| `group_session_list_panel.dart` | Group 会话列表 | 全文 |

### 🟡 参考文件 (相关逻辑)

| 文件 | 用途 |
|------|------|
| `agent_list_screen.dart` | Agent 列表 + 菜单 |
| `remote_agent_list_screen.dart` | Remote Agent 列表 + 菜单 |
| `remote_agent_detail_screen.dart` | Remote Agent 复杂编辑 |
| `channel_list_screen.dart` | 频道列表 |

### 🟢 模型文件 (数据定义)

| 文件 | 数据模型 |
|------|---------|
| `models/agent.dart` | Agent 数据模型 |
| `models/remote_agent.dart` | RemoteAgent 数据模型 |
| `models/channel.dart` | Channel/Group 数据模型 |

---

## 🔍 搜索技巧

### 搜索条件 1: 找所有菜单
```bash
grep -r "PopupMenuButton\|more_vert\|showMenu" lib/
```
**结果位置**:
- `agent_list_screen.dart:278`
- `remote_agent_list_screen.dart:377`
- `chat_screen.dart:1339`
- `channel_list_screen.dart:185`

### 搜索条件 2: 找所有编辑入口
```bash
grep -r "_isEditing\|Icons.edit" lib/screens/
```
**结果位置**:
- `agent_detail_screen.dart:28, 125, 177`
- `remote_agent_detail_screen.dart:45, 193`
- `group_detail_screen.dart:34, 88`

### 搜索条件 3: 找所有 API 调用
```bash
grep -r "updateAgent\|updateChannel\|updateRemoteAgent" lib/
```

---

## 💡 开发技巧

### 技巧 1: 快速进入编辑模式
只需调用:
```dart
setState(() => _isEditing = true);
```
所有 `enabled: _isEditing` 的字段会自动启用。

### 技巧 2: 快速保存编辑
1. 验证表单: `_formKey.currentState!.validate()`
2. 创建新对象 (保持 immutable)
3. 调用 API: `await _apiService.updateXxx()`
4. 更新 UI: `setState(() => _isEditing = false)`

### 技巧 3: 检查是否在编辑模式
```dart
if (_isEditing) {
  // 显示保存/取消按钮
} else {
  // 显示编辑按钮
}
```

### 技巧 4: 从菜单快速导航到编辑
使用 `startInEditMode: true` 参数:
```dart
GroupDetailScreen(
  channel: channel,
  startInEditMode: true,  // 直接进入编辑模式
)
```

---

## ⚠️ 常见错误避免

### ❌ 错误 1: 忘记在编辑后设置 `_isEditing = false`
```dart
// ❌ 错误: 保存后仍在编辑模式
await _apiService.updateAgent(agent);
// setState(() => _isEditing = false);  // 忘记了!

// ✅ 正确:
await _apiService.updateAgent(agent);
setState(() => _isEditing = false);
```

### ❌ 错误 2: 直接修改字段而不用 TextEditingController
```dart
// ❌ 错误: 字段可能不会更新
agent.name = "new name";

// ✅ 正确:
_nameController.text = "new name";
```

### ❌ 错误 3: 在编辑模式下没有禁用字段
```dart
// ❌ 错误: 所有模式下都可编辑
TextFormField(
  controller: _nameController,
  // enabled 属性缺失
)

// ✅ 正确:
TextFormField(
  controller: _nameController,
  enabled: _isEditing,  // 仅在编辑模式启用
)
```

---

## 🎓 学习路径

### 初级: 理解基本流程
1. 阅读 `CODE_EXPLORATION_SUMMARY.md` - 整体架构
2. 查看 `chat_menu.dart` - 菜单定义
3. 查看 `agent_detail_screen.dart` - 编辑实现

### 中级: 修改现有功能
1. 在菜单中添加新选项 (`chat_menu.dart`)
2. 在编辑页面中添加新字段 (`agent_detail_screen.dart`)
3. 更新 API 调用以支持新字段 (`local_api_service.dart`)

### 高级: 扩展新功能
1. 理解完整的数据流
2. 学习 Provider 模式进行跨屏幕通信
3. 实现复杂的编辑场景 (`remote_agent_detail_screen.dart`)

---

## 📚 相关文档

- **CODE_EXPLORATION_SUMMARY.md** - 详细的代码探索报告
- **ARCHITECTURE_DIAGRAM.md** - 可视化架构图
- **QUICK_REFERENCE.md** - 本文件，快速查询

