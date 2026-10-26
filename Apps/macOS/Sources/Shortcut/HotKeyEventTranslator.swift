import UtterCore

/// Carbon のホットキーの押下・解放を `ShortcutInterpreter` の入力に変換する（REC-01, REC-02）。
///
/// RegisterEventHotKey は押しっぱなしでもキーリピートを届けないため、押下はすべてリピートでない押下として渡す。
/// 解放を取りこぼした後の押下も新しい押下になり、`ShortcutInterpreter` の回復（録音中の押下で停止）が働く。
/// 押下を受けていない解放は、登録前から押されていたキーの解放なので捨てる。
struct HotKeyEventTranslator: Hashable, Sendable {
  private(set) var isPressed = false

  mutating func translate(_ phase: HotKeyPhase) -> ShortcutInput? {
    switch phase {
    case .pressed:
      isPressed = true
      return .shortcutPressed(isRepeat: false)
    case .released:
      guard isPressed else { return nil }
      isPressed = false
      return .shortcutReleased
    }
  }

  /// スリープ・登録の解除などで解放を取りこぼしうるときに呼ぶ。
  mutating func reset() {
    isPressed = false
  }
}
