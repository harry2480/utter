/// 前面アプリから選ぶ文体の区分（CTX-01）。クラウドへ送る文脈はこの区分と辞書語に限る（CTX-03）。
public enum RefinementStyle: Hashable, Sendable, CaseIterable {
  /// 区分を特定できないときの既定
  case standard
  /// Discord / Slack などのチャット
  case concise
  /// メール
  case polite
  /// IDE。技術語を保持する
  case technical
  /// Terminal。コマンドを保護する
  case command
  /// 文書アプリ。段落を整形する
  case document
}
