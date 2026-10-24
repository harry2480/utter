import CoreGraphics
import Foundation

/// イベントタップのコールバックから取り出した値。CGEvent そのものは MainActor へ持ち込まない。
struct TapEvent: Sendable {
  let type: CGEventType
  let keyCode: Int
  let flags: UInt64
  let isRepeat: Bool
}

/// CGEventTap の薄いラッパー。メインのランループで動かし、コールバックは MainActor で処理する。
@MainActor
final class EventTap {
  enum Mode: String {
    /// 監視のみ（入力監視の権限）。イベントを止められない
    case listen
    /// 能動的なフィルタ（アクセシビリティの権限）。イベントを止められる
    case `default`

    var options: CGEventTapOptions {
      self == .listen ? .listenOnly : .defaultTap
    }
  }

  /// 戻り値が `true` ならイベントを通し、`false` なら止める（listen では無視される）
  typealias Handler = @MainActor (TapEvent) -> Bool

  let mode: Mode
  private let handler: Handler
  private let onDisabled: @MainActor (CGEventType) -> Void
  private var port: CFMachPort?
  private var source: CFRunLoopSource?

  init(
    mode: Mode,
    handler: @escaping Handler,
    onDisabled: @escaping @MainActor (CGEventType) -> Void
  ) {
    self.mode = mode
    self.handler = handler
    self.onDisabled = onDisabled
  }

  /// タップを作成する。権限がないと作成に失敗する（`false`）。
  func install(events: [CGEventType], enabled: Bool) -> Bool {
    let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: mode.options,
        eventsOfInterest: mask,
        callback: eventTapCallback,
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

  isolated deinit {
    invalidate()
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

  fileprivate func dispatch(_ event: TapEvent) -> Bool {
    switch event.type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      onDisabled(event.type)
      return true
    default:
      return handler(event)
    }
  }
}

private func eventTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
  let tapEvent = TapEvent(
    type: type,
    keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
    flags: event.flags.rawValue,
    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
  )
  // タップのランループソースはメインのランループに追加しているので、ここはメインスレッドで呼ばれる
  let passes = MainActor.assumeIsolated { tap.dispatch(tapEvent) }
  return passes ? Unmanaged.passUnretained(event) : nil
}
