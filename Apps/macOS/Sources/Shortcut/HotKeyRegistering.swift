import Carbon.HIToolbox

/// グローバルなホットキーの登録（REC-01, REC-02）。本番は `CarbonHotKeyRegistrar`、テストは Stub を使う。
@MainActor
protocol HotKeyRegistering: AnyObject {
  /// 登録する。押下・解放は `handler` で受け取る。登録中は `unregister` するまで `handler` を保持する。
  func register(
    _ spec: CarbonHotKeySpec,
    handler: @escaping @MainActor (HotKeyPhase) -> Void
  ) -> Result<HotKeyRegistrationID, HotKeyRegistrationFailure>

  /// 登録を解除する。解除後は `handler` を呼ばない。
  func unregister(_ id: HotKeyRegistrationID)
}

/// ホットキーのイベントの種類。
enum HotKeyPhase: Hashable, Sendable {
  case pressed
  case released
}

struct HotKeyRegistrationID: Hashable, Sendable {
  let rawValue: UInt32
}

/// 登録の失敗。
enum HotKeyRegistrationFailure: Error, Hashable, Sendable {
  /// 同じ組み合わせが他で排他登録済み（eventHotKeyExistsErr）。他アプリとの競合
  case alreadyRegistered
  /// イベントハンドラを登録できない
  case handlerUnavailable(OSStatus)
  /// その他の失敗（eventHotKeyInvalidErr 等）
  case rejected(OSStatus)

  /// RegisterEventHotKey の結果から作る。
  init(registrationStatus status: OSStatus) {
    self = status == OSStatus(eventHotKeyExistsErr) ? .alreadyRegistered : .rejected(status)
  }
}
