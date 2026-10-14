/// 挿入の経路（INS-02, 13章）。macOS の各経路と iOS の `UITextDocumentProxy` を共通の値で表す。
public enum InsertionRoute: Hashable, Sendable, CaseIterable {
  /// Accessibility API による直接挿入（macOS）
  case accessibility
  /// 許可済みの Pasteboard 経由の貼り付け（macOS）
  case pasteboard
  /// 許可済みの CGEvent によるキー入力（macOS）
  case keyEvents
  /// `UITextDocumentProxy.insertText`（iOS キーボード）
  case textDocumentProxy
}
