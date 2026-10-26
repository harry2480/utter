/// マイクの使用許可の状態（PERM-01）。
public enum MicrophoneAuthorization: Hashable, Sendable {
  /// まだ利用者に尋ねていない
  case notDetermined
  case authorized
  /// 利用者が拒否した
  case denied
  /// 管理者の設定などで使えない
  case restricted
}

/// マイクの使用許可を確かめ、要求する口（PERM-01）。
///
/// 本番実装は OS の API を使うため各アプリに置き、テストは `StubMicrophoneAccess` を使う。
public protocol MicrophoneAccess: Sendable {
  /// 現在の状態
  func authorization() async -> MicrophoneAuthorization
  /// 利用者に許可を求める。許可されたら `true`
  func requestAccess() async -> Bool
}

extension MicrophoneAccess {
  /// 録音の前に使用許可を確かめる。未確認なら要求する（初めて録音するときに要求する, PERM-01）。
  /// - Throws: 拒否・制限されていれば、要求し直さずに投げる
  public func ensureAccess() async throws(AudioRecorderError) {
    switch await authorization() {
    case .authorized:
      return
    case .notDetermined:
      guard await requestAccess() else { throw .microphoneAccessDenied }
    case .denied:
      throw .microphoneAccessDenied
    case .restricted:
      throw .microphoneAccessRestricted
    }
  }
}
