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
  /// 同じ組み合わせが登録済み（eventHotKeyExistsErr）。他アプリとの競合として扱う。
  ///
  /// eventHotKeyExistsErr は、他のプロセスが排他で登録済みのときのほか、同じプロセスの中での二重登録でも返る
  /// （CarbonEventsCore.h）。utter は録音と Edit Mode を1つの登録者で登録するが、どちらも登録の前に前の登録を解除し、
  /// Edit Mode は録音と同じ組み合わせを断る。録音の割当を Edit Mode が使っていた組み合わせに変えるときも、
  /// `ShortcutAssignments` が Edit Mode に先に手放させる。そのため utter の中の二重登録では返らない前提で、
  /// 他のアプリとの競合として表示する（`GlobalShortcutStatusText`、`ShortcutAssignmentsTests` で確かめる）
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
