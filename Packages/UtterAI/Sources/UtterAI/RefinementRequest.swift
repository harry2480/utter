/// 整形プロバイダーへの入力。
///
/// 持てるのは STT テキスト・整形モード・スタイル区分・辞書語だけで、
/// ウィンドウタイトル・入力欄の既存本文・URL などの文脈は持たない（CTX-03）。
/// プロパティを足す場合は CTX-03 に照らして可否を判断し、`RefinementRequestTests` のサイズ検査も更新する。
public struct RefinementRequest: Hashable, Sendable {
  /// 整形対象の STT テキスト。指示ではなくデータとして扱う（TXT-04）
  public let text: String
  public let mode: RefinementMode
  public let style: RefinementStyle
  /// 表記を保つ辞書語
  public let dictionaryTerms: [String]

  public init(
    text: String,
    mode: RefinementMode,
    style: RefinementStyle = .standard,
    dictionaryTerms: [String] = []
  ) {
    self.text = text
    self.mode = mode
    self.style = style
    self.dictionaryTerms = dictionaryTerms
  }
}

// 発話本文と辞書語をログに出さないよう、文字列表現とリフレクションには件数と文字数だけを出す。
extension RefinementRequest: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "RefinementRequest(mode: \(mode), style: \(style), length: \(text.count), dictionaryTerms: \(dictionaryTerms.count))"
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "mode": mode, "style": style, "length": text.count,
        "dictionaryTerms": dictionaryTerms.count,
      ]
    )
  }
}
