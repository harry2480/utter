import UtterText

/// `EditRouter` の結果。編集案か、編集できなかった理由を持つ（AC-14）。
///
/// 送信しないローカルでは音声指示による編集ができないため、整形と違ってローカルの結果に退避しない。
/// 編集できなかった場合、呼び出し側は選択範囲を変えずに HUD で通知する。
public struct EditOutcome: Hashable, Sendable {
  public enum Content: Hashable, Sendable {
    /// `EditSession.propose(_:)` に渡す編集案
    case proposal(String)
    /// 編集できなかった
    case notEdited(EditFailureReason)
  }

  public let content: Content
  /// クラウドが応答した場合のトークン使用量（AI-05）。検証失敗の場合も、課金されているため残す
  public let usage: TokenUsage?

  public init(content: Content, usage: TokenUsage? = nil) {
    self.content = content
    self.usage = usage
  }

  /// 編集案。編集できなかった場合は `nil`
  public var proposedText: String? {
    guard case .proposal(let text) = content else {
      return nil
    }
    return text
  }

  /// 編集できなかった理由。編集案があれば `nil`
  public var failureReason: EditFailureReason? {
    guard case .notEdited(let reason) = content else {
      return nil
    }
    return reason
  }
}

/// 編集できなかった理由。HUD で通知するために使う。本文は持たない。
public enum EditFailureReason: Hashable, Sendable {
  /// 音声指示が空。送信しない
  case emptyInstruction
  /// 送信先への選択テキストの送信の同意がない。プロバイダーは呼ばない（AC-06）
  case consentNotGranted
  /// 同意を確認した送信先と、`EditRouter` のプロバイダーの送信先が違う（アプリ側の組み合わせの誤り）。
  /// 別の送信先への同意で送らないよう、プロバイダーは呼ばない（AC-06）
  case destinationMismatch
  /// 入力先が機密入力（パスワード欄・機密アプリ・除外アプリ・判定不能）のため送信しない。プロバイダーは呼ばない（7章, AC-12）
  case sensitiveInputSuppressed
  /// プロバイダーが失敗した。予算超過は `.budgetExceeded`、上限時間の超過は `.timeout` になる
  case providerFailed(AIProviderError)
  /// 応答が検証を通らなかった
  case validationFailed(EditValidationFailure)
}

// 編集案をログに出さないよう、文字列表現とリフレクションには種類と文字数だけを出す。
extension EditOutcome: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "EditOutcome(content: \(content), usage: \(usage.map(String.init(describing:)) ?? "nil"))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["content": content, "usage": usage as Any])
  }
}

extension EditOutcome.Content: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .proposal(let text): "proposal(length: \(text.count))"
    case .notEdited(let reason): "notEdited(\(reason))"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}

extension EditSession {
  /// `EditRouter` の結果を受け取る。編集案があれば `propose(_:)` して `true` を返す。
  ///
  /// 編集できなかった場合は状態を変えずに `false` を返す。確認中なら前の編集案のまま、待機中なら待機のまま残る。
  @discardableResult
  public mutating func propose(_ outcome: EditOutcome) throws(EditSessionError) -> Bool {
    guard let text = outcome.proposedText else {
      return false
    }
    try propose(text)
    return true
  }
}
