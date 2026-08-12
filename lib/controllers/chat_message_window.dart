/// In-memory chat list windowing — keep a recent slice, load older on demand.
abstract final class ChatMessageWindow {
  /// First paint / channel open.
  static const int initialLimit = 80;

  /// Older-page size when the user scrolls toward history.
  static const int pageSize = 50;

  /// Soft cap when reloading from DB after the user has paged up.
  static const int maxCached = 300;

  /// Auto-collapse markdown/text bubbles longer than this (chars).
  static const int longContentChars = 2500;
}
