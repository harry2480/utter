/// 非同期処理から状態機械へ届く結果。
public struct SessionEvent: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case recognitionCompleted
    case refinementCompleted
    case insertionCompleted
    /// 現在の段階で失敗した
    case failed
  }

  /// 処理を依頼した時点のトークン
  public let token: SessionToken
  public let kind: Kind

  public init(token: SessionToken, kind: Kind) {
    self.token = token
    self.kind = kind
  }
}

/// イベントを処理した結果。
public enum SessionEventOutcome: Hashable, Sendable {
  /// 遷移した。値は遷移後の状態
  case applied(SessionPhase)
  /// 遅延イベントとして破棄した
  case discarded(SessionEventDiscardReason)
}

public enum SessionEventDiscardReason: Hashable, Sendable {
  /// キャンセル・完了済み、または別のセッションのイベント
  case inactiveSession
  /// 同じセッションの、すでに過ぎた段階のイベント
  case sequenceMismatch
}

/// 現在のセッション・段階に宛てたイベントだが、その状態では許可されていない遷移。
public enum SessionTransitionError: Error, Hashable, Sendable {
  case invalidTransition(from: SessionPhase, event: SessionEvent.Kind)
}
