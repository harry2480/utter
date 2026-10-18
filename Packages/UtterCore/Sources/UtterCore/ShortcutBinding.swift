/// 登録済みのショートカット。競合検出の比較対象（REC-02）。
///
/// utter 自身の割当のほか、アプリ側が把握しているシステムや他アプリの割当も表す。
public struct ShortcutBinding: Hashable, Sendable {
  /// 割当を識別する名前（例: `"utter.record"`, `"system.spotlight"`）。発話本文や利用者の入力を入れない。
  public let id: String
  public let combination: KeyCombination

  public init(id: String, combination: KeyCombination) {
    self.id = id
    self.combination = combination
  }
}
