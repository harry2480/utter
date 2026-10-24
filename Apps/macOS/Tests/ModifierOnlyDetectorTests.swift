import Carbon.HIToolbox
import CoreGraphics
import Testing
import UtterCore

/// 修飾キーの flagsChanged。`down` は押下後のフラグ（離したときは残りのフラグ）
func flagsChanged(_ key: ModifierOnlyKey, down: Bool, others: UInt64 = 0) -> KeyTapEvent {
  let generic: CGEventFlags =
    switch key.modifier {
    case .command: .maskCommand
    case .option: .maskAlternate
    case .control: .maskControl
    case .shift: .maskShift
    default: .maskSecondaryFn
    }
  let flags = down ? generic.rawValue | key.downMask | others : others
  return KeyTapEvent(kind: .flagsChanged, keyCode: key.keyCode, flags: flags)
}

/// 通常のキーの押下（内容は問わない）
let otherKeyDown = KeyTapEvent(kind: .keyDown, keyCode: kVK_ANSI_A)

struct ModifierOnlyDetectorTests {
  @Test("REC-02: Push-to-talk は修飾キー単独の押下で押下、解放で解放として渡す")
  func pushToTalkFiresOnPress() {
    var detector = ModifierOnlyDetector(key: .rightOption, firing: .onPress)
    #expect(detector.handle(flagsChanged(.rightOption, down: true)) == [.pressed])
    #expect(detector.isDown)
    #expect(detector.handle(flagsChanged(.rightOption, down: false)) == [.released])
    #expect(!detector.isDown)
  }

  @Test("REC-01: Toggle は他のキーを挟まずに離したときだけ、押下＋解放として渡す")
  func toggleFiresOnCleanRelease() {
    var detector = ModifierOnlyDetector(key: .function, firing: .onCleanRelease)
    #expect(detector.handle(flagsChanged(.function, down: true)).isEmpty)
    #expect(detector.handle(flagsChanged(.function, down: false)) == [.pressed, .released])
  }

  @Test("REC-02: Toggle で押下中に通常のキー・他の修飾キーが押されたら、修飾キーとしての使用とみなして渡さない")
  func toggleIgnoresCombinedUse() {
    var detector = ModifierOnlyDetector(key: .rightOption, firing: .onCleanRelease)
    _ = detector.handle(flagsChanged(.rightOption, down: true))
    #expect(detector.handle(otherKeyDown).isEmpty)
    #expect(detector.handle(flagsChanged(.rightOption, down: false)).isEmpty)

    _ = detector.handle(flagsChanged(.rightOption, down: true))
    let rightOptionFlags = CGEventFlags.maskAlternate.rawValue | DeviceFlags.rightOption
    let shiftDown = KeyTapEvent(
      kind: .flagsChanged, keyCode: kVK_Shift,
      flags: rightOptionFlags | CGEventFlags.maskShift.rawValue | DeviceFlags.leftShift)
    #expect(detector.handle(shiftDown).isEmpty)
    #expect(detector.handle(flagsChanged(.rightOption, down: false)).isEmpty)

    // 次の単独押下は渡す
    _ = detector.handle(flagsChanged(.rightOption, down: true))
    #expect(detector.handle(flagsChanged(.rightOption, down: false)) == [.pressed, .released])
  }

  @Test(
    "REC-02: 押下時に他の修飾キーが押されていれば、別のショートカットの途中とみなして渡さない",
    arguments: [ModifierOnlyDetector.Firing.onPress, .onCleanRelease])
  func ignoresPressWithOtherModifiers(_ firing: ModifierOnlyDetector.Firing) {
    var detector = ModifierOnlyDetector(key: .rightOption, firing: firing)
    let command = CGEventFlags.maskCommand.rawValue | DeviceFlags.leftCommand
    #expect(detector.handle(flagsChanged(.rightOption, down: true, others: command)).isEmpty)
    #expect(detector.handle(flagsChanged(.rightOption, down: false, others: command)).isEmpty)
  }

  @Test("REC-02: 左右を区別する。反対側だけの押下は無視し、反対側を押したままの押下は渡さない")
  func distinguishesSides() {
    var detector = ModifierOnlyDetector(key: .rightOption, firing: .onPress)
    #expect(detector.handle(flagsChanged(.leftOption, down: true)).isEmpty)
    #expect(detector.handle(flagsChanged(.leftOption, down: false)).isEmpty)
    #expect(!detector.isDown)

    // 左 Option を押したまま右 Option
    let leftHeld = CGEventFlags.maskAlternate.rawValue | DeviceFlags.leftOption
    #expect(detector.handle(flagsChanged(.rightOption, down: true, others: leftHeld)).isEmpty)
    #expect(detector.handle(flagsChanged(.rightOption, down: false, others: leftHeld)).isEmpty)
  }

  @Test("REC-02: Push-to-talk の押下中に通常のキーが押されても、解放は渡す")
  func pushToTalkReleasesAfterOtherKey() {
    var detector = ModifierOnlyDetector(key: .function, firing: .onPress)
    #expect(detector.handle(flagsChanged(.function, down: true)) == [.pressed])
    #expect(detector.handle(otherKeyDown).isEmpty)
    #expect(detector.handle(flagsChanged(.function, down: false)) == [.released])
  }

  @Test("REC-02: reset 後は押下中の状態を破棄し、取りこぼした解放の後の押下を新しい押下として扱う")
  func resetDropsHeldState() {
    var detector = ModifierOnlyDetector(key: .function, firing: .onPress)
    _ = detector.handle(flagsChanged(.function, down: true))
    detector.reset()
    #expect(!detector.isDown)
    // 解放は押下を受けていないので渡さない
    #expect(detector.handle(flagsChanged(.function, down: false)).isEmpty)
    #expect(detector.handle(flagsChanged(.function, down: true)) == [.pressed])
  }

  @Test("REC-02: 修飾キー単独の物理キーと UtterCore の修飾キーの対応")
  func keyMapping() throws {
    #expect(ModifierOnlyKey.rightOption.combination == KeyCombination(modifierOnly: .option))
    let fn = try #require(KeyCombination(modifierOnly: .function))
    #expect(ModifierOnlyKey(combination: fn) == .function)
    // 左右を決められない修飾キー単独・修飾キーの組み合わせは物理キーにしない
    let option = try #require(KeyCombination(modifierOnly: .option))
    #expect(ModifierOnlyKey(combination: option) == nil)
    let fnShift = try #require(KeyCombination(modifierOnly: [.function, .shift]))
    #expect(ModifierOnlyKey(combination: fnShift) == nil)
    #expect(Set(ModifierOnlyKey.allCases.map(\.keyCode)).count == ModifierOnlyKey.allCases.count)
  }
}
