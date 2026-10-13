/// 整形プロバイダーの応答。
public struct RefinementResponse: Hashable, Sendable {
  /// 整形後のテキスト。空の場合もあり、検証は呼び出し側が行う
  public let text: String
  /// トークン使用量（AI-05）。使用量を返さないプロバイダーでは `nil`
  public let usage: TokenUsage?

  public init(text: String, usage: TokenUsage? = nil) {
    self.text = text
    self.usage = usage
  }
}

// 整形後の本文をログに出さないよう、文字列表現とリフレクションには文字数だけを出す。
extension RefinementResponse: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "RefinementResponse(length: \(text.count), usage: \(usage.map(String.init(describing:)) ?? "nil"))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["length": text.count, "usage": usage as Any])
  }
}

/// 1回の整形で消費したトークン数（AI-05）。費用の推定は単価表の設定と組み合わせて別に行う。
public struct TokenUsage: Hashable, Sendable {
  public let inputTokens: Int
  public let outputTokens: Int

  public init(inputTokens: Int, outputTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}
