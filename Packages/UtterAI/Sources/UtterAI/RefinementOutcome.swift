/// Refinement Router の結果。挿入する本文と、その出どころを持つ（4.1節, AC-16）。
public struct RefinementOutcome: Hashable, Sendable {
  public enum Source: Hashable, Sendable {
    /// クラウド整形の応答が検証を通った
    case cloud
    /// Raw モードのため送信せず、STT テキストをそのまま返した
    case raw
    /// ローカル整形の結果に退避した
    case localFallback(RefinementFallbackReason)
  }

  /// 挿入する本文
  public let text: String
  public let source: Source
  /// クラウドが応答した場合のトークン使用量（AI-05）。検証失敗で退避した場合も、課金されているため残す
  public let usage: TokenUsage?
  /// 予算の台帳に記録した推定費用と計上した月（AI-05）。記録していなければ `nil`。
  /// 表示・通知用。永続化は `BudgetGuard` の `onRecord` で行う（キャンセルで結果が返らない場合も記録額を失わないため）
  public let recordedCost: RecordedEstimatedCost?

  public init(
    text: String, source: Source, usage: TokenUsage? = nil,
    recordedCost: RecordedEstimatedCost? = nil
  ) {
    self.text = text
    self.source = source
    self.usage = usage
    self.recordedCost = recordedCost
  }

  /// 退避した理由。クラウド整形の結果なら `nil`
  public var fallbackReason: RefinementFallbackReason? {
    guard case .localFallback(let reason) = source else {
      return nil
    }
    return reason
  }
}

// 本文をログに出さないよう、文字列表現とリフレクションには出どころと文字数だけを出す。
extension RefinementOutcome: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "RefinementOutcome(source: \(source), length: \(text.count), usage: \(usage.map(String.init(describing:)) ?? "nil"), recordedCost: \(recordedCost.map(String.init(describing:)) ?? "nil"))"
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "source": source, "length": text.count, "usage": usage as Any,
        "recordedCost": recordedCost as Any,
      ])
  }
}

/// ローカル整形に退避した理由。HUD で退避を通知するために使う（4.1節）。
public enum RefinementFallbackReason: Hashable, Sendable {
  /// クラウド送信の同意がない。プロバイダーは呼ばない（AC-06）
  case consentNotGranted
  /// 入力先が機密入力（パスワード欄・機密アプリ・除外アプリ・判定不能）のため送信しない。プロバイダーは呼ばない（7章, AC-12）
  case sensitiveInputSuppressed
  /// プロバイダーが失敗した。上限時間の超過は `.timeout` になる
  case providerFailed(AIProviderError)
  /// 応答が検証を通らなかった
  case validationFailed(RefinementValidationFailure)
}
