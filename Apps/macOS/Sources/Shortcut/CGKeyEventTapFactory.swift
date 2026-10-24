import ApplicationServices
import CoreGraphics

/// CGEventTap によるイベントタップの作成（REC-01, REC-02。#51 の判定待ち）。
///
/// セッションのイベントタップをメインのランループに追加し、コールバックは MainActor で処理する。
/// listenOnly は入力監視、defaultTap はアクセシビリティの権限がないと作成に失敗する（HotkeyProbe の想定。人が実機で確かめる）。
/// イベントの内容は記録しない。
@MainActor
final class CGKeyEventTapFactory: KeyEventTapFactory {
  init() {}

  func makeTap(
    mode: KeyEventTapMode,
    events: Set<KeyTapEventKind>,
    enabled: Bool,
    handler: @escaping @MainActor (KeyTapEvent) -> Bool,
    onDisabled: @escaping @MainActor () -> Void
  ) -> (any KeyEventTap)? {
    let tap = CGKeyEventTap(handler: handler, onDisabled: onDisabled)
    guard tap.install(mode: mode, events: events, enabled: enabled) else { return nil }
    return tap
  }
}

@MainActor
final class CGKeyEventTap: KeyEventTap {
  private let handler: @MainActor (KeyTapEvent) -> Bool
  private let onDisabled: @MainActor () -> Void
  private var port: CFMachPort?
  private var source: CFRunLoopSource?

  init(
    handler: @escaping @MainActor (KeyTapEvent) -> Bool,
    onDisabled: @escaping @MainActor () -> Void
  ) {
    self.handler = handler
    self.onDisabled = onDisabled
  }

  isolated deinit {
    invalidate()
  }

  fileprivate func install(mode: KeyEventTapMode, events: Set<KeyTapEventKind>, enabled: Bool)
    -> Bool
  {
    let mask = events.reduce(CGEventMask(0)) { mask, kind in
      mask | (CGEventMask(1) << Self.eventType(for: kind).rawValue)
    }
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: mode == .listen ? .listenOnly : .defaultTap,
        eventsOfInterest: mask,
        callback: keyEventTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else { return false }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: enabled)
    self.port = port
    self.source = source
    return true
  }

  var isEnabled: Bool {
    guard let port else { return false }
    return CGEvent.tapIsEnabled(tap: port)
  }

  func setEnabled(_ enabled: Bool) {
    guard let port else { return }
    CGEvent.tapEnable(tap: port, enable: enabled)
  }

  func invalidate() {
    if let port {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    port = nil
    source = nil
  }

  fileprivate func dispatch(type: CGEventType, event: KeyTapEvent?) -> Bool {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      onDisabled()
      return true
    default:
      // invalidate 後に届いたイベントと、対象外の種類は通す
      guard port != nil, let event else { return true }
      return handler(event)
    }
  }

  fileprivate nonisolated static func kind(for type: CGEventType) -> KeyTapEventKind? {
    switch type {
    case .keyDown: .keyDown
    case .keyUp: .keyUp
    case .flagsChanged: .flagsChanged
    default: nil
    }
  }

  private static func eventType(for kind: KeyTapEventKind) -> CGEventType {
    switch kind {
    case .keyDown: .keyDown
    case .keyUp: .keyUp
    case .flagsChanged: .flagsChanged
    }
  }
}

/// CGEventTap のコールバック。C の関数ポインタとして渡すため、状態を持たないグローバル関数にする。
private func keyEventTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let tapEvent = CGKeyEventTap.kind(for: type).map { kind in
    KeyTapEvent(
      kind: kind,
      keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
      flags: event.flags.rawValue,
      isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    )
  }
  // ポインタは Sendable ではないため、アドレスの値として MainActor に渡す
  let address = UInt(bitPattern: userInfo)
  // タップのランループソースはメインのランループに追加しているので、ここはメインスレッドで呼ばれる。
  // userInfo のタップは invalidate（deinit を含む）でポートを外すまで生存する
  let passes = MainActor.assumeIsolated { () -> Bool in
    guard let pointer = UnsafeRawPointer(bitPattern: address) else { return true }
    return Unmanaged<CGKeyEventTap>.fromOpaque(pointer).takeUnretainedValue()
      .dispatch(type: type, event: tapEvent)
  }
  return passes ? Unmanaged.passUnretained(event) : nil
}

/// 入力監視・アクセシビリティの確認と要求（PERM-01, PERM-02）。
///
/// 権限は utter のアプリに対して判定・要求される。許可の変更が起動中のプロセスに反映されるか
/// （再起動が必要か）は人が実機で確かめる。
@MainActor
final class SystemEventTapPermissions: EventTapPermissionChecking {
  init() {}

  func isGranted(_ permission: EventTapPermission) -> Bool {
    switch permission {
    case .inputMonitoring: CGPreflightListenEventAccess()
    case .accessibility: AXIsProcessTrusted()
    }
  }

  func request(_ permission: EventTapPermission) {
    switch permission {
    case .inputMonitoring:
      _ = CGRequestListenEventAccess()
    case .accessibility:
      // kAXTrustedCheckOptionPrompt の実体の文字列。C のグローバル変数は Swift 6 で並行安全でないため直接使わない
      let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }
  }
}
