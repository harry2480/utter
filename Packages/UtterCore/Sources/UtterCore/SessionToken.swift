/// 処理を依頼した時点のセッションと段階を表す。
///
/// 認識・整形・挿入などの非同期処理は依頼時のトークンを結果に添えて返す。
/// 状態機械は現在のトークンと一致しない結果を、キャンセル済みまたは古い段階の遅延イベントとして破棄する。
public struct SessionToken: Hashable, Sendable {
  public let sessionID: SessionID
  /// セッション内の順序番号。状態が進むたびに増える。
  public let sequence: UInt64

  public init(sessionID: SessionID, sequence: UInt64) {
    self.sessionID = sessionID
    self.sequence = sequence
  }
}
