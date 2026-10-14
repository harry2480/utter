import UtterCore

/// 現在のセッションに属し、順序どおりに届いたイベントだけを通す（4章）。
///
/// キャンセル済み・完了済み・別のセッションのイベントと、すでに受け取った順序番号以前のイベントを破棄する。
/// 順序番号の欠け（1 の次に 3）は受け付ける。値型なので、利用側は `@MainActor` や `actor` に隔離して保持する。
///
/// `SessionStateMachine` との分担: このフィルターは認識ストリームの中の順序を、
/// `SessionStateMachine.handle(_:)` はセッションの段階を判定する。`RecognitionEvent.sequence` は
/// 認識イベントの通し番号で、`SessionToken.sequence`（段階の番号）とは別物。
/// `completed` / `failed` は、呼び出し側が認識を依頼したときに保持した `SessionToken` で
/// `SessionEvent` に変換して状態機械へ渡す。
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

  /// `session` が現在のセッションならキャンセルし、以後のイベントをすべて破棄する。
  ///
  /// 遅れて届いたキャンセルで新しいセッションを止めないよう、別のセッションなら何もせず `false` を返す。
  /// `SessionStateMachine.cancel()` が返した ID をそのまま渡せる。
  @discardableResult
  public mutating func cancel(_ session: SessionID) -> Bool {
    guard activeSession == session else { return false }
    finish()
    return true
  }

  private mutating func finish() {
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
      finish()
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
