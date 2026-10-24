import UtterCore

/// イベントタップのイベントから、修飾キー単独ショートカットの押下・解放を判定する（REC-01, REC-02。#51 の判定待ち）。
///
/// 判定結果は Carbon のホットキーと同じ `HotKeyPhase` にし、`HotKeyEventTranslator` → `ShortcutInterpreter` に渡す。
/// 押下時に他の修飾キー（同じ種類の反対側を含む）が押されていれば、別のショートカットの途中とみなして扱わない。
/// 通常のキーは「押下中に押されたか」だけを使い、どのキーかは保持しない。
struct ModifierOnlyDetector: Hashable, Sendable {
  /// いつショートカットとして扱うか
  enum Firing: Hashable, Sendable {
    /// 押下で押下、解放で解放として渡す（Push-to-talk）
    case onPress
    /// 他のキーを挟まずに離したときだけ、押下＋解放として渡す（Toggle）。
    /// 右 Option での記号入力や Fn+F キーなど、修飾キーとしての通常の使い方では反応しない
    case onCleanRelease

    init(mode: ShortcutTriggerMode) {
      self = mode == .pushToTalk ? .onPress : .onCleanRelease
    }
  }

  let key: ModifierOnlyKey
  let firing: Firing
  private(set) var isDown = false
  /// 今回の押下をショートカットとして扱っているか
  private var accepted = false
  private var otherKeyDuringHold = false

  init(key: ModifierOnlyKey, firing: Firing) {
    self.key = key
    self.firing = firing
  }

  /// イベントを判定する。ショートカットとして渡すものがなければ空。
  mutating func handle(_ event: KeyTapEvent) -> [HotKeyPhase] {
    switch event.kind {
    case .keyDown:
      if isDown { otherKeyDuringHold = true }
      return []
    case .keyUp:
      return []
    case .flagsChanged:
      return handleFlagsChanged(event)
    }
  }

  /// タップの無効化などで押下状態が信用できなくなったときに呼ぶ。
  mutating func reset() {
    isDown = false
    accepted = false
    otherKeyDuringHold = false
  }

  private mutating func handleFlagsChanged(_ event: KeyTapEvent) -> [HotKeyPhase] {
    guard event.keyCode == key.keyCode else {
      // 対象以外の修飾キーが押下中に変化した
      if isDown { otherKeyDuringHold = true }
      return []
    }
    let downNow = event.flags & key.downMask != 0
    if downNow, !isDown {
      isDown = true
      otherKeyDuringHold = false
      accepted = !key.othersDown(flags: event.flags)
      return accepted && firing == .onPress ? [.pressed] : []
    }
    if !downNow, isDown {
      isDown = false
      defer { accepted = false }
      switch firing {
      case .onPress:
        return accepted ? [.released] : []
      case .onCleanRelease:
        return accepted && !otherKeyDuringHold ? [.pressed, .released] : []
      }
    }
    return []
  }
}
