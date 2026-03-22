/// Stream events emitted by [LocalLLMAgentService.chat].
///
/// Distinguishes plain text tokens from tool-call invocations so that
/// [ChatService] can dispatch interactive UI components (action_confirmation,
/// single_select, etc.) the same way it does for remote ACP agents.
sealed class LLMStreamEvent {}

/// A chunk of streamed text content.
class LLMTextEvent extends LLMStreamEvent {
  final String text;
  LLMTextEvent(this.text);
}

/// The LLM invoked a UI tool via function calling / tool_use.
class LLMToolCallEvent extends LLMStreamEvent {
  final String id;

  /// Tool name, e.g. `action_confirmation`, `single_select`, …
  final String name;

  /// Parsed arguments – structure matches the corresponding widget metadata.
  final Map<String, dynamic> arguments;

  LLMToolCallEvent({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

/// Emitted at the end of a streaming response round, carrying the stop reason
/// and the raw assistant message content (used to build multi-round history).
class LLMDoneEvent extends LLMStreamEvent {
  /// Why the LLM stopped: 'stop', 'tool_calls', 'end_turn', 'max_tokens', etc.
  final String stopReason;

  /// The raw assistant message content for constructing multi-round history.
  /// For OpenAI: the full `choices[0].message`-equivalent map.
  /// For Claude: the full `content` array.
  final Map<String, dynamic>? rawAssistantMessage;

  LLMDoneEvent({
    required this.stopReason,
    this.rawAssistantMessage,
  });
}
