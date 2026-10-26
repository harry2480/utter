import Testing
import UtterCore

struct ShortcutNotationTests {
  @Test("REC-01: ctrl+option+k 形式の指定を解釈する")
  func parses() throws {
    let k = try #require(ShortcutKey(rawValue: "k"))
    #expect(
      ShortcutNotation.parse("ctrl+option+k")
        == KeyCombination(key: k, modifiers: [.control, .option]))
    #expect(
      ShortcutNotation.parse(" Cmd + Shift + Space ")
        == KeyCombination(key: .space, modifiers: [.command, .shift]))
    #expect(ShortcutNotation.parse("esc") == .escape)
    #expect(ShortcutNotation.parse("fn") == KeyCombination(modifierOnly: .function))
  }

  @Test("REC-01: 通常のキーが2つ以上・空の指定は解釈しない", arguments: ["ctrl+a+b", "", "ctrl++k", "ctrl+"])
  func rejects(_ text: String) {
    #expect(ShortcutNotation.parse(text) == nil)
  }

  @Test("REC-02: メニューの表記は macOS と同じ修飾キーの順にする")
  func displays() throws {
    let k = try #require(ShortcutKey(rawValue: "k"))
    #expect(
      ShortcutNotation.display(
        KeyCombination(key: k, modifiers: [.command, .shift, .option, .control])) == "⌃⌥⇧⌘K")
    #expect(ShortcutNotation.display(KeyCombination(key: .space, modifiers: .option)) == "⌥Space")
    #expect(
      ShortcutNotation.display(KeyCombination(key: try #require(ShortcutKey(rawValue: "f5"))))
        == "F5")
  }

  @Test("REC-02: 使えない理由を利用者向けの文言にする")
  func statusText() throws {
    let target = GlobalShortcutSetting(
      combination: KeyCombination(key: .space, modifiers: .command), mode: .pushToTalk)
    #expect(GlobalShortcutStatusText.text(for: .unassigned) == "ショートカット: 未設定")
    #expect(GlobalShortcutStatusText.text(for: .active(target)) == "ショートカット: ⌘Space（Push-to-talk）")
    #expect(
      GlobalShortcutStatusText.text(
        for: .unavailable(
          target, .invalid([.conflict(bindingID: "system.index.0", kind: .identical)])))
        == "ショートカット ⌘Space を使えません: システムのショートカットと重なっています")
    #expect(
      GlobalShortcutStatusText.reasonText(.registrationFailed(.alreadyRegistered))
        == "他のアプリが同じ組み合わせを使っています")
  }
}
