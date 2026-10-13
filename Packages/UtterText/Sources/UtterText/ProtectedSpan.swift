/// 整形で壊してはいけないテキスト上の範囲（TXT-02）。
public struct ProtectedSpan: Hashable, Sendable {
  /// 保護対象の種類。宣言順が抽出の優先順位で、範囲が重なる場合は先の種類を採用する。
  public enum Kind: Hashable, Sendable, CaseIterable {
    /// ```` ``` ```` で囲まれたコードブロック
    case codeBlock
    /// `` ` `` で囲まれたインラインコード
    case inlineCode
    case url
    /// 呼び出し側から渡された辞書語
    case dictionaryTerm
    case number
  }

  public let kind: Kind
  /// 抽出元のテキストにおける範囲
  public let range: Range<String.Index>
  public let text: String

  public init(kind: Kind, range: Range<String.Index>, text: String) {
    self.kind = kind
    self.range = range
    self.text = text
  }
}

// 発話本文をログに出さないよう、文字列表現とリフレクションには種類と文字数だけを出す。
extension ProtectedSpan: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "ProtectedSpan(kind: \(kind), length: \(text.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["kind": kind, "length": text.count])
  }
}
