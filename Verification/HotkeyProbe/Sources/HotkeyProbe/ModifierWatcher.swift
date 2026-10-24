import AppKit
import CoreGraphics
import UtterCore

/// 修飾キー単独の押下・解放を検出する。
///
/// 記録するのは対象の修飾キーの押下・解放と、押下中に「他のキーが押されたか」の有無だけ。
/// 他のキーのキーコードや文字は記録しない。
@MainActor
final class ModifierWatcher {
  enum Backend: String {
    /// CGEventTap
    case tap
    /// NSEvent.addGlobalMonitorForEvents（監視のみ）
    case nsevent
  }

  enum Change {
    /// 押下。`othersDown` は押下時に他の修飾キーが押されていたか
    case down(othersDown: Bool)
    /// 解放。`otherKeyDuringHold` は押下中に他のキー（通常キー・修飾キー）が押されたか
    case up(heldMs: Double, otherKeyDuringHold: Bool)
  }

  let target: ModifierTarget
  private let log: ProbeLog
  private let onChange: @MainActor (Change) -> Void
  /// タップが無効化されて押下状態が信用できなくなったときに呼ぶ
  var onReset: (@MainActor () -> Void)?
  private var isDown = false
  private var downAt: UInt64 = 0
  private var otherKeyDuringHold = false
  private var tap: EventTap?
  private var monitor: Any?

  init(target: ModifierTarget, log: ProbeLog, onChange: @escaping @MainActor (Change) -> Void) {
    self.target = target
    self.log = log
    self.onChange = onChange
  }

  /// 監視を始める。`includeKeyEvents` が `false` なら flagsChanged だけを対象にする
  /// （その場合「押下中に通常キーが押されたか」は分からない）。
  func start(backend: Backend, tapMode: EventTap.Mode, includeKeyEvents: Bool) -> Bool {
    switch backend {
    case .tap:
      let tap = EventTap(
        mode: tapMode,
        handler: { [weak self] event in
          self?.handleTap(event)
          // 修飾キーの監視ではイベントを止めない
          return true
        },
        onDisabled: { [weak self] type in
          self?.handleTapDisabled(type)
        }
      )
      var events: [CGEventType] = [.flagsChanged]
      if includeKeyEvents { events.append(.keyDown) }
      guard tap.install(events: events, enabled: true) else { return false }
      self.tap = tap
      return true
    case .nsevent:
      var mask: NSEvent.EventTypeMask = [.flagsChanged]
      if includeKeyEvents { mask.insert(.keyDown) }
      monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
        let tapEvent = TapEvent(
          type: event.type == .flagsChanged ? .flagsChanged : .keyDown,
          keyCode: Int(event.keyCode),
          flags: UInt64(event.modifierFlags.rawValue),
          isRepeat: event.type == .keyDown ? event.isARepeat : false
        )
        MainActor.assumeIsolated { self?.handleTap(tapEvent) }
      }
      // 権限がなくてもモニタ自体は返ることがあるため、イベントが届くかを人が確かめる
      return monitor != nil
    }
  }

  func stop() {
    tap?.invalidate()
    tap = nil
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
  }

  private func handleTap(_ event: TapEvent) {
    switch event.type {
    case .keyDown:
      // 通常キーの内容は記録しない。押下中に押されたという事実だけを残す
      if isDown { otherKeyDuringHold = true }
    case .flagsChanged:
      handleFlagsChanged(event)
    default:
      break
    }
  }

  private func handleFlagsChanged(_ event: TapEvent) {
    let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    guard target.keyCodes.contains(event.keyCode) else {
      // 対象以外の修飾キーが押下中に変化した
      if isDown { otherKeyDuringHold = true }
      return
    }
    let downNow = event.flags & target.downMask != 0
    if downNow, !isDown {
      isDown = true
      downAt = now
      otherKeyDuringHold = false
      let othersDown = target.othersDown(flags: event.flags)
      log.write(
        "modifier",
        "\(target.name) down keyCode=\(event.keyCode) flags=0x\(String(event.flags, radix: 16)) 他の修飾キー押下中=\(othersDown)"
      )
      onChange(.down(othersDown: othersDown))
    } else if !downNow, isDown {
      isDown = false
      let heldMs = Double(now - downAt) / 1_000_000
      log.write(
        "modifier",
        "\(target.name) up 押下時間=\(String(format: "%.1f", heldMs))ms 押下中の他キー入力=\(otherKeyDuringHold)（内容は記録しない）"
      )
      onChange(.up(heldMs: heldMs, otherKeyDuringHold: otherKeyDuringHold))
    }
  }

  private func handleTapDisabled(_ type: CGEventType) {
    log.write(
      "tap", "タップが無効化された: \(type == .tapDisabledByTimeout ? "timeout" : "userInput")。再有効化する")
    tap?.setEnabled(true)
    isDown = false
    onReset?()
  }
}
