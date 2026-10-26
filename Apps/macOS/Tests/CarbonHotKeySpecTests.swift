import Carbon.HIToolbox
import Testing
import UtterCore

private func combination(_ text: String) throws -> KeyCombination {
  try #require(ShortcutNotation.parse(text))
}

struct CarbonHotKeySpecTests {
  @Test("REC-01: キー名を仮想キーコードに変換する")
  func keyCodes() throws {
    #expect(
      MacKeyCodes.keyCode(for: try #require(ShortcutKey(rawValue: "a"))) == UInt32(kVK_ANSI_A))
    #expect(MacKeyCodes.keyCode(for: .space) == UInt32(kVK_Space))
    #expect(MacKeyCodes.keyCode(for: try #require(ShortcutKey(rawValue: "F5"))) == UInt32(kVK_F5))
    #expect(MacKeyCodes.keyCode(for: try #require(ShortcutKey(rawValue: "f20"))) == UInt32(kVK_F20))
    #expect(
      MacKeyCodes.keyCode(for: try #require(ShortcutKey(rawValue: "kana"))) == UInt32(kVK_JIS_Kana))
    #expect(MacKeyCodes.keyCode(for: try #require(ShortcutKey(rawValue: "f21"))) == nil)
  }

  @Test("REC-02: 仮想キーコードを照合用のキーに戻す。対応表にないコードは utter の割当と一致しない名前にする")
  func keysFromCodes() {
    #expect(MacKeyCodes.key(forKeyCode: UInt32(kVK_ANSI_K))?.rawValue == "k")
    #expect(MacKeyCodes.key(forKeyCode: UInt32(kVK_F1))?.rawValue == "f1")
    #expect(MacKeyCodes.key(forKeyCode: 0xFFFF)?.rawValue == "keycode-65535")
  }

  @Test("REC-01: 修飾キーを Carbon の値に変換する")
  func carbonModifiers() {
    #expect(CarbonHotKeySpec.carbonModifiers(for: []) == 0)
    #expect(CarbonHotKeySpec.carbonModifiers(for: .command) == UInt32(cmdKey))
    #expect(
      CarbonHotKeySpec.carbonModifiers(for: [.control, .option, .shift, .command])
        == UInt32(controlKey | optionKey | shiftKey | cmdKey))
  }

  @Test("REC-01: 通常のキー組み合わせを登録内容にする")
  func makesSpec() throws {
    let spec = try CarbonHotKeySpec.make(for: combination("ctrl+option+k")).get()
    #expect(
      spec
        == CarbonHotKeySpec(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)))
  }

  @Test(
    "REC-01: F キーは修飾キーなし・Shift だけでも登録できる。修飾キー付きの Esc も登録できる",
    arguments: ["f5", "shift+f13", "cmd+esc"])
  func functionKeysWithoutModifiers(_ text: String) throws {
    #expect(throws: Never.self) { try CarbonHotKeySpec.make(for: combination(text)).get() }
  }

  @Test(
    "REC-02: 登録できない組み合わせを理由つきで返す",
    arguments: [
      ("option", HotKeySpecIssue.modifierOnly),
      ("fn+f5", .functionModifier),
      ("cmd+f21", .unsupportedKey),
      ("k", .missingModifier),
      ("shift+space", .missingModifier),
      ("left", .missingModifier),
      ("return", .missingModifier),
      ("kana", .missingModifier),
    ])
  func rejects(_ text: String, _ issue: HotKeySpecIssue) throws {
    #expect(throws: issue) { try CarbonHotKeySpec.make(for: combination(text)).get() }
  }

  @Test("REC-02: RegisterEventHotKey の失敗を競合とそれ以外に分ける")
  func registrationFailures() {
    #expect(
      HotKeyRegistrationFailure(registrationStatus: OSStatus(eventHotKeyExistsErr))
        == .alreadyRegistered)
    #expect(
      HotKeyRegistrationFailure(registrationStatus: OSStatus(eventHotKeyInvalidErr))
        == .rejected(OSStatus(eventHotKeyInvalidErr)))
  }
}
