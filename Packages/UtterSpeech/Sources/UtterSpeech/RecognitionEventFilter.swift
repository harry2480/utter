import UtterCore

/// 現在のセッションに属し、順序どおりに届いたイベントだけを通す（4章）。
///
/// キャンセル済み・完了済み・別のセッションのイベントと、すでに受け取った順序番号以前のイベントを破棄する。
/// 値型なので、利用側は `@MainActor` や `actor` に隔離して保持する。
public struct RecognitionEventFilter: Hashable, Sendable {
  /// イベントを受け付けているセッション。キャンセル・完了後は `nil`
  public private(set) var activeSession: SessionID?
  /// 最後に受け付けた順序番号
  public private(set) var lastSequence: UInt64?

  public init() {}

  /// 新しいセッションのイベントを受け付け始める。それまでのセッションのイベントは以後破棄する。
  public mutating func begin(_ session: SessionID) {
    activeSession = session
    lastSequence = nil
  }

  /// 現在のセッションをキャンセルし、以後のイベントをすべて破棄する。
  public mutating func cancel() {
    activeSession = nil
    lastSequence = nil
  }

  /// イベントを受け付けるなら `nil`、破棄するなら理由を返す。`completed` / `failed` を受け付けるとセッションを終える。
  public mutating func accept(_ event: RecognitionEvent) -> RecognitionEventDiscardReason? {
    guard let activeSession, activeSession == event.sessionID else {
      return .inactiveSession
    }
    if let lastSequence, event.sequence <= lastSequence {
      return .outOfOrder
    }
    lastSequence = event.sequence
    if event.kind.isTerminal {
      cancel()
    }
    return nil
  }
}

public enum RecognitionEventDiscardReason: Hashable, Sendable {
  /// キャンセル・完了済み、または別のセッションのイベント
  case inactiveSession
  /// すでに受け取った順序番号以前のイベント
  case outOfOrder
}
