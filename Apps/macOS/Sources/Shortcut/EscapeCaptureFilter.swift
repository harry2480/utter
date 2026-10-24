import Carbon.HIToolbox
import UtterCore

/// セッション中だけ Esc を捕捉して他アプリへ渡さないかの判定（REC-01。#51 の判定待ち）。
///
/// - 捕捉するのは、セッション中（`ShortcutInterpreter.capturesEscape(in:)`）の修飾キーなしの Esc の押下だけ
/// - 修飾キー付きの Esc（⌘Esc、⌥⌘Esc 等）は通す。ただし Push-to-talk ではトリガーを押したまま Esc を押すため、
///   トリガーの修飾キー（`ignoredModifiers`）は修飾キー付きかの判定から除く
/// - 止めた Esc のキーリピートと解放も止める。リピートでない押下が来たら、前回の解放を取りこぼしたとみなす
/// - Fn は判定に含めない（HotkeyProbe と同じ）
struct EscapeCaptureFilter: Hashable, Sendable {
  enum Verdict: Hashable, Sendable {
    /// 他アプリへそのまま渡す
    case pass
    /// 止める（捕捉した Esc のリピート・解放）
    case swallow
    /// 止めて、セッションをキャンセルする
    case cancel
  }

  /// 修飾キー付きの Esc の判定から除く修飾キー（Push-to-talk のトリガーの修飾キー）
  let ignoredModifiers: ShortcutModifiers
  /// 止めた Esc の解放を待っているか
  private(set) var isSwallowingUntilKeyUp = false

  private static let escapeModifiers: ShortcutModifiers = [.command, .option, .control, .shift]

  init(ignoredModifiers: ShortcutModifiers) {
    self.ignoredModifiers = ignoredModifiers
  }

  /// Push-to-talk ではトリガーの修飾キーを除く。Toggle ではトリガーを押し続けないため除かない。
  init(mode: ShortcutTriggerMode, triggerModifiers: ShortcutModifiers) {
    self.init(ignoredModifiers: mode == .pushToTalk ? triggerModifiers : [])
  }

  /// タップを有効にしておく必要があるか。待機中で、止めた Esc の解放も待っていなければ無効にできる
  func needsTap(capturing: Bool) -> Bool {
    capturing || isSwallowingUntilKeyUp
  }

  /// - Parameter capturing: セッション中か（`ShortcutInterpreter.capturesEscape(in:)`）
  mutating func handle(_ event: KeyTapEvent, capturing: Bool) -> Verdict {
    guard event.keyCode == kVK_Escape else { return .pass }
    switch event.kind {
    case .flagsChanged:
      return .pass
    case .keyUp:
      guard isSwallowingUntilKeyUp else { return .pass }
      isSwallowingUntilKeyUp = false
      return .swallow
    case .keyDown:
      if isSwallowingUntilKeyUp {
        if event.isRepeat { return .swallow }
        // リピートでない押下が来たら、前回の解放を取りこぼしたとみなす
        isSwallowingUntilKeyUp = false
      }
      let modifiers = event.modifiers.intersection(Self.escapeModifiers).subtracting(
        ignoredModifiers)
      guard capturing, modifiers.isEmpty, !event.isRepeat else { return .pass }
      isSwallowingUntilKeyUp = true
      return .cancel
    }
  }

  /// タップの無効化などで解放を取りこぼしうるときに呼ぶ。
  mutating func reset() {
    isSwallowingUntilKeyUp = false
  }
}
