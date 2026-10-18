import Carbon.HIToolbox
import CoreGraphics
import UtterCore

/// セッション中だけ Esc を捕捉して他アプリへ渡さない（REC-01）。
///
/// 記録するのは Esc だけ。Esc 以外のキーはタップに届いても何も記録せずに通す。
@MainActor
final class EscapeCapture {
  enum Strategy: String {
    /// タップはセッション中だけ有効にする。待機中はタップ自体が無効でイベントを見ない
    case toggleTap = "toggle-tap"
    /// タップは常に有効にし、待機中は Esc を通す
    case filter
  }

  private let strategy: Strategy
  private let simulator: SessionSimulator
  private let log: ProbeLog
  private var tap: EventTap?
  /// 押下を止めた Esc の解放（とキーリピート）も止めるため、解放まで捕捉を続ける
  private var swallowingUntilKeyUp = false

  init(strategy: Strategy, simulator: SessionSimulator, log: ProbeLog) {
    self.strategy = strategy
    self.simulator = simulator
    self.log = log
  }

  func install(mode: EventTap.Mode) -> Bool {
    let tap = EventTap(
      mode: mode,
      handler: { [weak self] event in self?.handle(event) ?? true },
      onDisabled: { [weak self] type in self?.handleDisabled(type) }
    )
    guard tap.install(events: [.keyDown, .keyUp], enabled: shouldEnable) else { return false }
    self.tap = tap
    log.write(
      "esc", "Esc タップ作成 mode=\(mode.rawValue) strategy=\(strategy.rawValue) 有効=\(tap.isEnabled)")
    return true
  }

  /// セッションの状態が変わったら呼ぶ。
  func update() {
    guard let tap, strategy == .toggleTap else { return }
    let enable = shouldEnable
    guard tap.isEnabled != enable else { return }
    tap.setEnabled(enable)
    log.write("esc", "Esc タップを\(enable ? "有効" : "無効")にした")
  }

  func uninstall() {
    tap?.invalidate()
    tap = nil
  }

  private var shouldEnable: Bool {
    strategy == .filter || simulator.capturesEscape || swallowingUntilKeyUp
  }

  private func handle(_ event: TapEvent) -> Bool {
    guard event.keyCode == kVK_Escape else { return true }
    let flags = "flags=0x\(String(event.flags, radix: 16))"
    if event.type == .keyUp {
      guard swallowingUntilKeyUp else { return true }
      swallowingUntilKeyUp = false
      log.write("esc", "Esc keyUp を止めた \(flags)")
      update()
      return false
    }
    if swallowingUntilKeyUp {
      log.write("esc", "Esc keyDown（リピート=\(event.isRepeat)）を止めた \(flags)")
      return false
    }
    let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    if event.flags & modifiers.rawValue != 0 {
      log.write("esc", "修飾キー付きの Esc は通す \(flags)")
      return true
    }
    if event.isRepeat {
      log.write("esc", "Esc のキーリピートは通す \(flags)")
      return true
    }
    // キャンセルで状態が変わると update() が呼ばれるため、先に立てて keyUp まで有効のままにする
    swallowingUntilKeyUp = true
    let captured = simulator.handle(.escapePressed)
    swallowingUntilKeyUp = captured
    if captured {
      let note = tap?.mode == .listen ? "（listen のため実際には止められない）" : ""
      log.write("esc", "Esc を捕捉し他アプリへ渡さない\(note) \(flags)")
      return false
    }
    log.write("esc", "セッション外の Esc を通す \(flags)")
    return true
  }

  private func handleDisabled(_ type: CGEventType) {
    log.write("tap", "Esc タップが無効化された: \(type == .tapDisabledByTimeout ? "timeout" : "userInput")")
    if shouldEnable {
      tap?.setEnabled(true)
      log.write("tap", "Esc タップを再有効化した")
    }
  }
}
