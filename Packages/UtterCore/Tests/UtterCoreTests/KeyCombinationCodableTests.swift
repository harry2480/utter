import Foundation
import Testing

@testable import UtterCore

struct KeyCombinationCodableTests {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
  }

  private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
  }

  @Test("REC-01, REC-02: 通常のキーと修飾キーの組み合わせを保存・復元できる")
  func keyWithModifiersRoundTrips() throws {
    let combination = KeyCombination(key: .space, modifiers: [.option, .shift])

    #expect(try roundTrip(combination) == combination)
  }

  @Test("REC-02: 修飾キー単独の組み合わせも保存・復元できる（割り当てられるかは利用時に判定する）")
  func modifierOnlyRoundTrips() throws {
    let combination = try #require(KeyCombination(modifierOnly: [.function]))

    let decoded = try roundTrip(combination)

    #expect(decoded == combination)
    #expect(decoded.isModifierOnly)
  }

  @Test("REC-01, REC-02: 録音の操作方式を保存・復元できる", arguments: ShortcutTriggerMode.allCases)
  func triggerModeRoundTrips(mode: ShortcutTriggerMode) throws {
    #expect(try roundTrip(mode) == mode)
  }

  @Test("REC-01, REC-02: 録音の操作方式は case 名の文字列として保存する")
  func triggerModeIsStoredAsString() throws {
    #expect(try decode(ShortcutTriggerMode.self, #""toggle""#) == .toggle)
    #expect(try decode(ShortcutTriggerMode.self, #""pushToTalk""#) == .pushToTalk)
    #expect(
      String(decoding: try JSONEncoder().encode(ShortcutTriggerMode.pushToTalk), as: UTF8.self)
        == #""pushToTalk""#)
  }

  @Test("REC-02: 保存したキー名も前後の空白を除いて小文字にそろえる")
  func storedKeyNameIsNormalized() throws {
    let combination = try decode(KeyCombination.self, #"{"key": " Space ", "modifiers": 1}"#)

    #expect(combination == KeyCombination(key: .space, modifiers: [.command]))
  }

  @Test(
    "REC-02: キーも修飾キーもない・空のキー名・定義にない修飾キー・型違いは読み込みを失敗させる",
    arguments: [
      #"{"modifiers": 0}"#,
      #"{"key": null, "modifiers": 0}"#,
      #"{"key": "  ", "modifiers": 1}"#,
      #"{"key": "a", "modifiers": 32}"#,
      #"{"key": "a", "modifiers": 255}"#,
      #"{"key": "a", "modifiers": 256}"#,
      #"{"key": "a", "modifiers": -1}"#,
      #"{"key": "a"}"#,
      #"{"key": 3, "modifiers": 1}"#,
      #""space""#,
    ])
  func invalidCombinationFailsToDecode(json: String) {
    #expect(throws: DecodingError.self) {
      try decode(KeyCombination.self, json)
    }
  }

  @Test("REC-02: 定義済みの修飾キーはすべて読み込める")
  func allKnownModifiersDecode() throws {
    let all: ShortcutModifiers = [.command, .option, .control, .shift, .function]

    #expect(try roundTrip(all) == all)
    #expect(try decode(ShortcutModifiers.self, "31") == all)
  }
}
