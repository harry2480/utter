import Carbon.HIToolbox

/// RegisterEventHotKey によるグローバルなホットキーの登録（REC-01, REC-02）。
///
/// 通常のキー組み合わせは入力監視・アクセシビリティの権限なしで登録・受信できる（PERM-01。
/// HotkeyProbe の `hotkey` で実機確認する）。押下（kEventHotKeyPressed）と解放（kEventHotKeyReleased）の
/// 両方を受け取り、Push-to-talk の解放に使う。
///
/// 排他登録（kEventHotKeyExclusive）にして、他のプロセスが同じ組み合わせを排他登録済みなら
/// eventHotKeyExistsErr で失敗させ、競合として扱う。
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
  private var eventHandler: EventHandlerRef?
  private var hotKeys: [UInt32: Registered] = [:]
  private var nextID: UInt32 = 1
  /// EventHotKeyID の signature（'UTTR'）
  private nonisolated static let signature: OSType = 0x5554_5452

  private struct Registered {
    let ref: EventHotKeyRef
    let handler: @MainActor (HotKeyPhase) -> Void
  }

  init() {}

  isolated deinit {
    for registered in hotKeys.values {
      UnregisterEventHotKey(registered.ref)
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
  }

  func register(
    _ spec: CarbonHotKeySpec,
    handler: @escaping @MainActor (HotKeyPhase) -> Void
  ) -> Result<HotKeyRegistrationID, HotKeyRegistrationFailure> {
    let installStatus = installEventHandlerIfNeeded()
    guard installStatus == noErr else {
      return .failure(.handlerUnavailable(installStatus))
    }
    let id = nextID
    nextID &+= 1
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      spec.keyCode,
      spec.modifiers,
      EventHotKeyID(signature: Self.signature, id: id),
      GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive),
      &ref
    )
    guard status == noErr, let ref else {
      return .failure(HotKeyRegistrationFailure(registrationStatus: status))
    }
    hotKeys[id] = Registered(ref: ref, handler: handler)
    return .success(HotKeyRegistrationID(rawValue: id))
  }

  func unregister(_ id: HotKeyRegistrationID) {
    guard let registered = hotKeys.removeValue(forKey: id.rawValue) else { return }
    UnregisterEventHotKey(registered.ref)
  }

  fileprivate func dispatch(id: UInt32, phase: HotKeyPhase) {
    hotKeys[id]?.handler(phase)
  }

  private func installEventHandlerIfNeeded() -> OSStatus {
    guard eventHandler == nil else { return noErr }
    var specs = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    return InstallEventHandler(
      GetApplicationEventTarget(),
      carbonHotKeyCallback,
      specs.count,
      &specs,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
  }

  fileprivate nonisolated static func isOwn(_ hotKeyID: EventHotKeyID) -> Bool {
    hotKeyID.signature == signature
  }
}

/// Carbon のイベントハンドラ。C の関数ポインタとして渡すため、状態を持たないグローバル関数にする。
private func carbonHotKeyCallback(
  _ callRef: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userInfo: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr, CarbonHotKeyRegistrar.isOwn(hotKeyID) else {
    return OSStatus(eventNotHandledErr)
  }
  let phase: HotKeyPhase =
    GetEventKind(event) == UInt32(kEventHotKeyReleased) ? .released : .pressed
  let id = hotKeyID.id
  // ポインタは Sendable ではないため、アドレスの値として MainActor に渡す
  let address = UInt(bitPattern: userInfo)
  // アプリケーションのイベントターゲットへの配送はメインスレッドで行われる。
  // userInfo の登録者はハンドラを外すまで生存する（deinit で RemoveEventHandler する）
  MainActor.assumeIsolated {
    guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
    Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(pointer).takeUnretainedValue()
      .dispatch(id: id, phase: phase)
  }
  return noErr
}
