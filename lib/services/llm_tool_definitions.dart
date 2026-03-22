// JSON Schema definitions for the interactive UI tools that a local LLM
// can invoke via OpenAI function-calling or Claude tool_use.
//
// All definitions are now delegated to UIComponentRegistry, the single
// source of truth for UI component schemas.

import 'ui_component_registry.dart';

// ---------------------------------------------------------------------------
// OpenAI / GLM format  ({type: "function", function: {name, description, parameters}})
// ---------------------------------------------------------------------------

List<Map<String, dynamic>> openAITools() =>
    UIComponentRegistry.instance.openAITools();

// ---------------------------------------------------------------------------
// Claude (Anthropic) format  ({name, description, input_schema})
// ---------------------------------------------------------------------------

List<Map<String, dynamic>> claudeTools() =>
    UIComponentRegistry.instance.claudeTools();

// ---------------------------------------------------------------------------
// System prompt suffix — injected when UI tools are enabled
// ---------------------------------------------------------------------------

String get systemPromptSuffix => UIComponentRegistry.instance.systemPromptSuffix;
