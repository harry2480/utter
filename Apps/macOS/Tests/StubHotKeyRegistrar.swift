import Carbon.HIToolbox

/// テスト用のホットキー登録。OS には登録せず、登録内容を記録してイベントを手で送る。
@MainActor
final class StubHotKeyRegistrar: HotKeyRegistering {
  /// 次の登録で返す失敗。`nil` なら成功
  var nextFailure: HotKeyRegistrationFailure?
  /// 登録中と同じ組み合わせの登録を `.alreadyRegistered` で断るか。RegisterEventHotKey が同じプロセスの中の
  /// 二重登録に eventHotKeyExistsErr を返す（CarbonEventsCore.h）のをまねる
  var rejectsDuplicates = false
  /// 登録中と同じ組み合わせを登録しようとした回数（`rejectsDuplicates` によらず数える）
  private(set) var duplicateAttempts = 0
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
    if registered.values.contains(spec) {
      duplicateAttempts += 1
      if rejectsDuplicates { return .failure(.alreadyRegistered) }
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
