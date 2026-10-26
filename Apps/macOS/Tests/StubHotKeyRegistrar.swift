import Carbon.HIToolbox

/// テスト用のホットキー登録。OS には登録せず、登録内容を記録してイベントを手で送る。
@MainActor
final class StubHotKeyRegistrar: HotKeyRegistering {
  /// 次の登録で返す失敗。`nil` なら成功
  var nextFailure: HotKeyRegistrationFailure?
  private(set) var registered: [HotKeyRegistrationID: CarbonHotKeySpec] = [:]
  private(set) var unregisteredIDs: [HotKeyRegistrationID] = []
  private var handlers: [HotKeyRegistrationID: @MainActor (HotKeyPhase) -> Void] = [:]
  private var nextID: UInt32 = 1

  func register(
    _ spec: CarbonHotKeySpec,
    handler: @escaping @MainActor (HotKeyPhase) -> Void
  ) -> Result<HotKeyRegistrationID, HotKeyRegistrationFailure> {
    if let nextFailure {
      self.nextFailure = nil
      return .failure(nextFailure)
    }
    let id = HotKeyRegistrationID(rawValue: nextID)
    nextID += 1
    registered[id] = spec
    handlers[id] = handler
    return .success(id)
  }

  func unregister(_ id: HotKeyRegistrationID) {
    registered[id] = nil
    handlers[id] = nil
    unregisteredIDs.append(id)
  }

  /// 登録中のすべてのホットキーにイベントを送る。
  func send(_ phase: HotKeyPhase) {
    for handler in handlers.values {
      handler(phase)
    }
  }
}
