import Carbon.HIToolbox
import CoreGraphics
import Testing
import UtterCore

func escape(
  _ kind: KeyTapEventKind = .keyDown, flags: CGEventFlags = [], isRepeat: Bool = false
) -> KeyTapEvent {
  KeyTapEvent(kind: kind, keyCode: kVK_Escape, flags: flags.rawValue, isRepeat: isRepeat)
}

struct EscapeCaptureFilterTests {
  @Test("REC-01: セッション中の Esc は止めてキャンセルし、その解放も止める")
  func capturesDuringSession() {
    var filter = EscapeCaptureFilter(ignoredModifiers: [])
    #expect(filter.handle(escape(), capturing: true) == .cancel)
    #expect(filter.isSwallowingUntilKeyUp)
    // キャンセルで待機に戻っても、止めた Esc の解放までタップを残す
    #expect(filter.needsTap(capturing: false))
    #expect(filter.handle(escape(isRepeat: true), capturing: false) == .swallow)
    #expect(filter.handle(escape(.keyUp), capturing: false) == .swallow)
    #expect(!filter.needsTap(capturing: false))
  }

  @Test("REC-01: 待機中の Esc は他アプリへ渡す")
  func passesWhenIdle() {
    var filter = EscapeCaptureFilter(ignoredModifiers: [])
    #expect(!filter.needsTap(capturing: false))
    #expect(filter.handle(escape(), capturing: false) == .pass)
    #expect(filter.handle(escape(.keyUp), capturing: false) == .pass)
  }

  @Test(
    "REC-01: 修飾キー付きの Esc はセッション中でも通す",
    arguments: [
      CGEventFlags.maskCommand, .maskAlternate, .maskControl, .maskShift,
      [.maskCommand, .maskAlternate],
    ])
  func passesModifiedEscape(_ flags: CGEventFlags) {
    var filter = EscapeCaptureFilter(ignoredModifiers: [])
    #expect(filter.handle(escape(flags: flags), capturing: true) == .pass)
    #expect(filter.handle(escape(.keyUp, flags: flags), capturing: true) == .pass)
  }

  @Test("REC-01: Fn のフラグは修飾キー付きの判定に含めない")
  func ignoresFunctionFlag() {
    var filter = EscapeCaptureFilter(ignoredModifiers: [])
    #expect(filter.handle(escape(flags: .maskSecondaryFn), capturing: true) == .cancel)
  }

  @Test("REC-01 / REC-02: Push-to-talk ではトリガーの修飾キー付きの Esc も捕捉し、それ以外の修飾キー付きは通す")
  func pushToTalkIgnoresTriggerModifiers() {
    var filter = EscapeCaptureFilter(mode: .pushToTalk, triggerModifiers: [.control, .option])
    #expect(filter.ignoredModifiers == [.control, .option])
    #expect(
      filter.handle(escape(flags: [.maskControl, .maskAlternate]), capturing: true) == .cancel)
    _ = filter.handle(escape(.keyUp), capturing: false)
    #expect(
      filter.handle(escape(flags: [.maskControl, .maskCommand]), capturing: true) == .pass)
  }

  @Test("REC-01: Toggle ではトリガーを押し続けないため、トリガーの修飾キーを除かない")
  func toggleKeepsTriggerModifiers() {
    var filter = EscapeCaptureFilter(mode: .toggle, triggerModifiers: [.option])
    #expect(filter.ignoredModifiers.isEmpty)
    #expect(filter.handle(escape(flags: .maskAlternate), capturing: true) == .pass)
  }

  @Test("REC-01: セッション中に始まったキーリピートは捕捉しない（押下を止めていない Esc）")
  func passesRepeatNotStartedByCapture() {
    var filter = EscapeCaptureFilter(ignoredModifiers: [])
    #expect(filter.handle(escape(isRepeat: true), capturing: true) == .pass)
  }

  @Test("REC-01: Esc の解放を取りこぼした後の新しい押下は、改めて判定する")
  func recoversFromLostKeyUp() {
    var filter = EscapeCaptureFilter(ignoredModifiers: [])
    _ = filter.handle(escape(), capturing: true)
    // 解放が届かないまま待機中に新しい押下
    #expect(filter.handle(escape(), capturing: false) == .pass)
    #expect(!filter.isSwallowingUntilKeyUp)

    _ = filter.handle(escape(), capturing: true)
    filter.reset()
    #expect(filter.handle(escape(.keyUp), capturing: false) == .pass)
  }

  @Test("REC-01: Esc 以外のキーは判定せずに通す")
  func passesOtherKeys() {
    var filter = EscapeCaptureFilter(ignoredModifiers: [])
    #expect(filter.handle(otherKeyDown, capturing: true) == .pass)
    #expect(!filter.isSwallowingUntilKeyUp)
  }
}
