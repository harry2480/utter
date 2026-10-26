import Carbon.HIToolbox
import Testing
import UtterCore

struct SystemShortcutsTests {
  @Test("REC-02: Cmd 等の Carbon のビットがあれば一覧全体を Carbon 形式とみなし、0x20000 を Fn にする")
  func carbonFormat() throws {
    let f = try #require(ShortcutKey(rawValue: "f"))
    let entries: [SystemShortcuts.Entry?] = [
      .init(keyCode: kVK_Space, rawModifiers: cmdKey, enabled: true),
      .init(keyCode: kVK_ANSI_F, rawModifiers: 0x20000, enabled: true),
    ]
    let bindings = SystemShortcuts.enabledBindings(from: entries)
    #expect(
      bindings == [
        ShortcutBinding(
          id: "system.index.0", combination: KeyCombination(key: .space, modifiers: .command)),
        ShortcutBinding(
          id: "system.index.1",
          combination: KeyCombination(key: f, modifiers: .function)),
      ])
  }

  @Test("REC-02: NSEvent 形式の一覧では 0x20000 を Shift にする")
  func nsEventFormat() {
    let entries: [SystemShortcuts.Entry] = [
      .init(keyCode: kVK_Space, rawModifiers: 0x10_0000, enabled: true),
      .init(keyCode: kVK_ANSI_A, rawModifiers: 0x02_0000, enabled: true),
    ]
    #expect(SystemShortcuts.format(of: entries) == .nsEvent)
    #expect(SystemShortcuts.modifiers(fromRaw: 0x02_0000, format: .nsEvent) == .shift)
    #expect(
      SystemShortcuts.modifiers(fromRaw: 0x1C_0000, format: .nsEvent) == [
        .command, .option, .control,
      ])
  }

  @Test("REC-02: 形式を決められない一覧は判別不能として呼び出し側で Carbon 形式にする")
  func ambiguousFormat() {
    let entries: [SystemShortcuts.Entry?] = [
      .init(keyCode: kVK_ANSI_A, rawModifiers: 0x20000, enabled: true)
    ]
    #expect(SystemShortcuts.format(of: entries.compactMap { $0 }) == nil)
    #expect(
      SystemShortcuts.enabledBindings(from: entries).first?.combination.modifiers == .function)
  }

  @Test("REC-02: 無効な項目と読めなかった項目は競合の相手にしない。ID は一覧上の位置のまま")
  func skipsDisabledAndUnreadable() {
    let entries: [SystemShortcuts.Entry?] = [
      .init(keyCode: kVK_Space, rawModifiers: cmdKey, enabled: false),
      nil,
      .init(keyCode: kVK_ANSI_K, rawModifiers: cmdKey | shiftKey, enabled: true),
    ]
    #expect(SystemShortcuts.enabledBindings(from: entries).map(\.id) == ["system.index.2"])
  }

  @Test("REC-02: F キー・矢印キーの項目に付く Fn は外して照合する")
  func dropsFunctionOnFunctionAndArrowKeys() {
    let entries: [SystemShortcuts.Entry?] = [
      .init(keyCode: kVK_LeftArrow, rawModifiers: controlKey | 0x20000, enabled: true),
      .init(keyCode: kVK_F11, rawModifiers: 0x20000, enabled: true),
      .init(keyCode: kVK_Space, rawModifiers: cmdKey | 0x20000, enabled: true),
    ]
    let combinations = SystemShortcuts.enabledBindings(from: entries).map(\.combination.modifiers)
    #expect(combinations == [.control, [], [.command, .function]])
  }

  @Test("REC-02: NSEvent 形式の Fn（0x800000）を変換する")
  func nsEventFunction() {
    #expect(
      SystemShortcuts.modifiers(fromRaw: 0x84_0000, format: .nsEvent) == [.control, .function])
  }
}
