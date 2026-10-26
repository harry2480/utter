/// テスト用のイベントタップの作成。OS にはタップを作らず、作成内容を記録してイベントを手で送る。
@MainActor
final class StubKeyEventTapFactory: KeyEventTapFactory {
  /// `false` なら作成に失敗する
  var succeeds = true
  private(set) var created: [StubKeyEventTap] = []

  func makeTap(
    mode: KeyEventTapMode,
    events: Set<KeyTapEventKind>,
    enabled: Bool,
    handler: @escaping @MainActor (KeyTapEvent) -> Bool,
    onDisabled: @escaping @MainActor () -> Void
  ) -> (any KeyEventTap)? {
    guard succeeds else { return nil }
    let tap = StubKeyEventTap(
      mode: mode, events: events, isEnabled: enabled, handler: handler, onDisabled: onDisabled)
    created.append(tap)
    return tap
  }

  /// 作成済みで invalidate されていないタップ
  func live(_ mode: KeyEventTapMode) -> StubKeyEventTap? {
    created.last { $0.mode == mode && !$0.isInvalidated }
  }
}

@MainActor
final class StubKeyEventTap: KeyEventTap {
  let mode: KeyEventTapMode
  let events: Set<KeyTapEventKind>
  private(set) var isEnabled: Bool
  private(set) var isInvalidated = false
  private let handler: @MainActor (KeyTapEvent) -> Bool
  private let onDisabled: @MainActor () -> Void

  init(
    mode: KeyEventTapMode,
    events: Set<KeyTapEventKind>,
    isEnabled: Bool,
    handler: @escaping @MainActor (KeyTapEvent) -> Bool,
    onDisabled: @escaping @MainActor () -> Void
  ) {
    self.mode = mode
    self.events = events
    self.isEnabled = isEnabled
    self.handler = handler
    self.onDisabled = onDisabled
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
  }

  func invalidate() {
    isEnabled = false
    isInvalidated = true
  }

  /// イベントを送る。戻り値は他アプリへ渡すか。無効・invalidate 済みのタップには届かない（渡す）
  @discardableResult
  func send(_ event: KeyTapEvent) -> Bool {
    guard isEnabled, !isInvalidated else { return true }
    return handler(event)
  }

  /// OS がタップを無効化した想定
  func disableByOS() {
    isEnabled = false
    onDisabled()
  }
}

/// テスト用の権限。許可状態を手で切り替え、要求を記録する。
@MainActor
final class StubEventTapPermissions: EventTapPermissionChecking {
  var granted: Set<EventTapPermission> = []
  private(set) var checked: [EventTapPermission] = []
  private(set) var requested: [EventTapPermission] = []

  func isGranted(_ permission: EventTapPermission) -> Bool {
    checked.append(permission)
    return granted.contains(permission)
  }

  func request(_ permission: EventTapPermission) {
    requested.append(permission)
  }
}
