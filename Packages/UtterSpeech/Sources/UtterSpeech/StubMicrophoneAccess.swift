import Synchronization

/// 固定の状態と要求の結果を返すテスト用の `MicrophoneAccess`（PERM-01）。
///
/// 要求された回数を数え、許可を求める時機を確かめられる。要求の結果に応じて状態も変わる。
public final class StubMicrophoneAccess: MicrophoneAccess {
  private let state: Mutex<(authorization: MicrophoneAuthorization, requestCount: Int)>
  /// 要求したときの利用者の答え
  public let grantsOnRequest: Bool

  public init(authorization: MicrophoneAuthorization, grantsOnRequest: Bool = true) {
    state = Mutex((authorization, 0))
    self.grantsOnRequest = grantsOnRequest
  }

  /// 許可を求めた回数
  public var requestCount: Int {
    state.withLock { $0.requestCount }
  }

  public func authorization() async -> MicrophoneAuthorization {
    state.withLock { $0.authorization }
  }

  public func requestAccess() async -> Bool {
    let granted = grantsOnRequest
    return state.withLock { state in
      state.requestCount += 1
      // OS と同じく、尋ねるのは未確認のときだけ。答えた後は状態が決まる
      if state.authorization == .notDetermined {
        state.authorization = granted ? .authorized : .denied
      }
      return state.authorization == .authorized
    }
  }
}
