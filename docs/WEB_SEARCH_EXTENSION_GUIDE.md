# Web Search 工具扩展指南

## 概述

Shepaw 的 web search 功能支持通过可插拔的外部 CLI 工具扩展。这使得添加新的搜索引擎或自定义搜索逻辑变得简单而灵活。

## 架构

### 搜索引擎优先级

Web search 按以下优先级查找和使用搜索引擎：

1. **外部 CLI 工具**（via `CliToolRegistry`）
   - 命名空间 `brave-search` 
   - 如果工具已安装，优先使用

2. **内置提供者**（fallback）
   - Tavily Search（API Key 以 `tvly-` 开头或包含 `tavily`）
   - Brave Search（其他情况）

### 通信协议

外部工具通过 stdin/stdout JSON 与 Shepaw 通信。

**请求格式：**

```json
{
  "command": "search",
  "flags": {
    "query": "搜索关键词",
    "limit": 10,
    "apiKey": "API密钥"
  }
}
```

**响应格式：**

成功：
```json
{
  "success": true,
  "data": {
    "engine": "引擎名称",
    "query": "原始查询",
    "count": 10,
    "results": [
      {
        "title": "结果标题",
        "link": "https://example.com",
        "snippet": "摘要文本"
      }
    ]
  }
}
```

失败：
```json
{
  "success": false,
  "error": "错误信息"
}
```

## 现有工具：Brave Search

### 目录结构

```
~/shepaw/cli-tools/brave-search/
├── cli-tool.json      # 工具清单
├── handler.sh         # 执行脚本
└── README.md          # 文档
```

### 清单格式（cli-tool.json）

```json
{
  "namespace": "brave-search",
  "displayName": "Brave Search",
  "description": "Web search using Brave Search API",
  "version": "1.0.0",
  "supportedPlatforms": ["macos", "linux", "windows"],
  "handler": {
    "type": "script",
    "path": "handler.sh"
  },
  "commands": {
    "search": {
      "description": "Search the web using Brave Search API",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "搜索词" },
          "limit": { "type": "integer", "description": "结果数量" },
          "apiKey": { "type": "string", "description": "API Key" }
        },
        "required": ["query", "apiKey"]
      }
    }
  }
}
```

### Handler 脚本

`handler.sh` 是一个 bash 脚本，负责：
1. 解析 JSON 输入
2. 验证参数
3. 调用 Brave Search API
4. 格式化响应为 JSON

## 添加新搜索引擎

### 步骤 1：创建工具目录

```bash
mkdir -p ~/shepaw/cli-tools/<engine-name>
cd ~/shepaw/cli-tools/<engine-name>
```

### 步骤 2：创建 cli-tool.json

```json
{
  "namespace": "<engine-name>",
  "displayName": "<Display Name>",
  "description": "Web search using <Provider> API",
  "version": "1.0.0",
  "supportedPlatforms": ["macos", "linux", "windows"],
  "handler": {
    "type": "script",
    "path": "handler.sh"
  },
  "commands": {
    "search": {
      "description": "Search the web",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search query" },
          "limit": { "type": "integer", "description": "Result count" },
          "apiKey": { "type": "string", "description": "API Key" }
        },
        "required": ["query", "apiKey"]
      }
    }
  }
}
```

### 步骤 3：实现 Handler 脚本

```bash
#!/bin/bash

# 读取 JSON 输入
input=$(cat)

# 提取参数
command=$(echo "$input" | jq -r '.command // empty')
query=$(echo "$input" | jq -r '.flags.query // empty')
limit=$(echo "$input" | jq -r '.flags.limit // 10')
apiKey=$(echo "$input" | jq -r '.flags.apiKey // empty')

# 验证参数...
if [[ -z "$command" ]]; then
  echo '{"success": false, "error": "Missing command"}'
  exit 0
fi

# 调用 API...
# 解析响应...

# 返回标准格式的结果
echo "{\"success\": true, \"data\": {\"engine\": \"...\", \"query\": \"$query\", \"count\": 0, \"results\": []}}"
```

确保脚本可执行：
```bash
chmod +x handler.sh
```

### 步骤 4：安装和测试

工具会在 Shepaw 启动时自动扫描 `~/shepaw/cli-tools/` 目录。

测试：
```bash
# 配置 API Key
shepaw tools web.search.config --action set-key --value YOUR_API_KEY

# 执行搜索
shepaw tools web.search --query "测试" --limit 5
```

## 实现细节

### WebSearchService 集成

在 `lib/services/network/web_search/web_search_service.dart` 中：

```dart
// 尝试通过外部 CLI 工具执行
final result = await registry.executeCommand(
  'brave-search',
  'search',
  {
    'query': query,
    'limit': limit.toString(),
    'apiKey': apiKey,
  },
);
```

### Error Handling

如果外部工具：
- 未安装 → fallback 到内置提供者
- 执行失败 → fallback 到内置提供者
- 返回错误 → 直接返回该错误给用户

## 最佳实践

1. **错误处理**：确保脚本对所有错误情况返回有效的 JSON
2. **输入验证**：严格验证 API Key 和查询参数
3. **超时**：实现合理的超时时间（Shepaw 默认 30 秒）
4. **JSON 格式**：确保响应格式与协议完全一致
5. **日志**：考虑写入日志文件用于调试（需要用户配置）

## 示例：添加 Google 搜索

### 1. 创建目录
```bash
mkdir -p ~/shepaw/cli-tools/google-search
```

### 2. 创建 cli-tool.json
```json
{
  "namespace": "google-search",
  "displayName": "Google Search",
  "description": "Web search via Google Custom Search API",
  "version": "1.0.0",
  "supportedPlatforms": ["macos", "linux", "windows"],
  "handler": {
    "type": "script",
    "path": "handler.sh"
  },
  "commands": {
    "search": {
      "description": "Search the web using Google Custom Search",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string" },
          "limit": { "type": "integer" },
          "apiKey": { "type": "string" }
        },
        "required": ["query", "apiKey"]
      }
    }
  }
}
```

### 3. 实现 handler.sh
```bash
#!/bin/bash
input=$(cat)
command=$(echo "$input" | jq -r '.command')
query=$(echo "$input" | jq -r '.flags.query')
apiKey=$(echo "$input" | jq -r '.flags.apiKey')

# 调用 Google Custom Search API
response=$(curl -s "https://www.googleapis.com/customsearch/v1?q=$query&key=$apiKey&cx=...")

# 解析并格式化...
echo '{"success": true, "data": {...}}'
```

## 故障排查

### 工具未发现

确保：
- `~/shepaw/cli-tools/<namespace>/` 目录存在
- `cli-tool.json` 文件存在且格式正确
- `handler.sh` 存在且可执行 (`chmod +x`)
- 重启 Shepaw 或手动调用 rescan

### Handler 执行失败

检查：
- stdin 中的 JSON 格式是否正确
- handler 的错误输出（stderr）
- API 密钥是否有效
- 网络连接

### 性能问题

如果搜索很慢：
- 检查 API 响应时间
- 考虑添加缓存机制
- 使用 Shepaw 的超时参数

## 参考文档

- `CliToolRegistry` 实现：`lib/services/cli_tool_registry.dart`
- `WebSearchService` 实现：`lib/services/network/web_search/web_search_service.dart`
- 工具配置管理：`lib/services/tool_config_service.dart`
