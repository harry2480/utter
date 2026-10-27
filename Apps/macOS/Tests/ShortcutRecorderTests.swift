import AppKit
import Carbon.HIToolbox
import Testing
import UtterCore

struct ShortcutRecorderTests {
  private func key(_ name: String) throws -> ShortcutKey {
    try #require(ShortcutKey(rawValue: name))
  }

  private func down(_ code: Int, _ modifiers: ShortcutModifiers = []) -> ShortcutRecorder.Event {
    .keyDown(keyCode: UInt16(code), modifiers: modifiers)
  }

  // MARK: - キー入力の解釈

  @Test("REC-01: 修飾キーを押しながらのキーの押下を組み合わせにして記録を終える")
  func recordsKeyCombination() throws {
    var recorder = ShortcutRecorder(systemShortcuts: [])
    let expected = KeyCombination(key: try key("r"), modifiers: [.option, .command])

    #expect(recorder.handle(.flagsChanged(modifiers: .option)) == nil)
    #expect(recorder.handle(.flagsChanged(modifiers: [.option, .command])) == nil)
    #expect(recorder.handle(down(kVK_ANSI_R, [.option, .command])) == .recorded(expected))
  }

  @Test("REC-01: 修飾キーなしの Esc は記録の取り消しにする")
  func escapeCancels() {
    var recorder = ShortcutRecorder(systemShortcuts: [])

    #expect(recorder.handle(down(kVK_Escape)) == .cancelled)
  }

  @Test("REC-01: 修飾キー付きの Esc は取り消しにせず、組み合わせとして記録する")
  func modifiedEscapeIsRecorded() {
    var recorder = ShortcutRecorder(systemShortcuts: [])
    let expected = KeyCombination(key: .escape, modifiers: .control)

    #expect(recorder.handle(down(kVK_Escape, .control)) == .recorded(expected))
  }

  @Test("REC-01: 修飾キーだけを押して離すと、修飾キー単独として受け付けない")
  func modifierOnlyIsRejected() {
    var recorder = ShortcutRecorder(systemShortcuts: [])

    #expect(recorder.handle(.flagsChanged(modifiers: .command)) == nil)
    #expect(recorder.handle(.flagsChanged(modifiers: [.command, .shift])) == nil)
    #expect(recorder.handle(.flagsChanged(modifiers: .shift)) == nil)
    #expect(recorder.handle(.flagsChanged(modifiers: [])) == .rejected(.modifierOnly))
  }

  @Test("REC-01: Fn だけを押して離すと、Fn として受け付けない")
  func functionOnlyIsRejected() {
    var recorder = ShortcutRecorder(systemShortcuts: [])

    #expect(recorder.handle(.flagsChanged(modifiers: .function)) == nil)
    #expect(recorder.handle(.flagsChanged(modifiers: [])) == .rejected(.functionModifier))
  }

  @Test("REC-01: キーを押した後に修飾キーを離しても、修飾キー単独として扱わない")
  func releaseAfterKeyIsIgnored() {
    var recorder = ShortcutRecorder(systemShortcuts: [])

    #expect(recorder.handle(.flagsChanged(modifiers: .shift)) == nil)
    #expect(recorder.handle(down(kVK_ANSI_A, .shift)) == .rejected(.missingModifier))
    #expect(recorder.handle(.flagsChanged(modifiers: [])) == nil)
  }

  @Test("REC-01: 受け付けない入力の後も記録を続け、次の入力で記録できる")
  func continuesAfterRejection() throws {
    var recorder = ShortcutRecorder(systemShortcuts: [])
    let expected = KeyCombination(key: try key("k"), modifiers: .control)

    #expect(recorder.handle(down(kVK_ANSI_K)) == .rejected(.missingModifier))
    #expect(recorder.handle(down(kVK_ANSI_K, .control)) == .recorded(expected))
  }

  @Test("REC-01: 修飾キーなし・Shift だけの文字キー・Space・Return は受け付けない")
  func typingKeysNeedModifier() {
    var recorder = ShortcutRecorder(systemShortcuts: [])

    #expect(recorder.handle(down(kVK_ANSI_A)) == .rejected(.missingModifier))
    #expect(recorder.handle(down(kVK_Space, .shift)) == .rejected(.missingModifier))
    #expect(recorder.handle(down(kVK_Return)) == .rejected(.missingModifier))
  }

  @Test("REC-01: Fn を含む文字キーの組み合わせは受け付けない")
  func functionWithKeyIsRejected() {
    var recorder = ShortcutRecorder(systemShortcuts: [])
    let event = down(kVK_ANSI_A, [.function, .command])

    #expect(recorder.handle(event) == .rejected(.functionModifier))
  }

  @Test("REC-01: F キー・矢印キーに付く Fn のビットは外し、F キーは修飾キーなしでも記録する")
  func functionBitOnFunctionAndArrowKeysIsIgnored() throws {
    var recorder = ShortcutRecorder(systemShortcuts: [])
    let f5 = KeyCombination(key: try key("f5"))
    let left = KeyCombination(key: try key("left"), modifiers: .option)

    #expect(recorder.handle(down(kVK_F5, .function)) == .recorded(f5))
    #expect(recorder.handle(down(kVK_LeftArrow, [.function, .option])) == .recorded(left))
  }

  @Test("REC-01: 対応表にないキーは受け付けない")
  func unsupportedKeyIsRejected() {
    var recorder = ShortcutRecorder(systemShortcuts: [])

    #expect(recorder.handle(down(kVK_Home, .command)) == .rejected(.unsupportedKey))
    #expect(recorder.handle(down(kVK_ANSI_Minus, .command)) == .rejected(.unsupportedKey))
  }

  @Test("REC-02: 有効なシステムのショートカットと同じ組み合わせは受け付けない")
  func systemShortcutConflictIsRejected() {
    let spotlight = KeyCombination(key: .space, modifiers: .command)
    let system = [ShortcutBinding(id: "system.index.0", combination: spotlight)]
    var recorder = ShortcutRecorder(systemShortcuts: system)
    let other = KeyCombination(key: .space, modifiers: [.command, .option])

    #expect(recorder.handle(down(kVK_Space, .command)) == .rejected(.conflictsWithSystemShortcut))
    #expect(recorder.handle(down(kVK_Space, [.command, .option])) == .recorded(other))
  }

  // MARK: - 判定

  @Test("REC-01: 登録できない組み合わせの理由を返し、登録できる組み合わせには返さない")
  func issueForCombination() throws {
    let valid = KeyCombination(key: try key("r"), modifiers: [.option, .command])
    let optionOnly = try #require(KeyCombination(modifierOnly: .option))

    #expect(ShortcutRecorder.issue(for: valid, systemShortcuts: []) == nil)
    #expect(ShortcutRecorder.issue(for: optionOnly, systemShortcuts: []) == .modifierOnly)
    #expect(ShortcutRecorder.issue(for: .escape, systemShortcuts: []) == .missingModifier)
  }

  // MARK: - 修飾キーの変換

  @Test("REC-01: NSEvent の修飾キーを変換し、Caps Lock・テンキーのビットは使わない")
  func convertsModifierFlags() {
    let flags: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
    let all: ShortcutModifiers = [.command, .option, .control, .shift, .function]

    #expect(ShortcutRecorder.modifiers(from: flags) == all)
    #expect(ShortcutRecorder.modifiers(from: [.capsLock, .numericPad, .command]) == .command)
    #expect(ShortcutRecorder.modifiers(from: []) == [])
  }

  // MARK: - 表示

  @Test("REC-01: 現在の割当を macOS のメニューと同じ表記で出し、未設定なら「未設定」と出す")
  func displayText() throws {
    let optionCommandR = KeyCombination(key: try key("r"), modifiers: [.command, .option])
    let controlShiftSpace = KeyCombination(key: .space, modifiers: [.shift, .control])

    #expect(ShortcutRecorder.displayText(for: optionCommandR) == "⌥⌘R")
    #expect(ShortcutRecorder.displayText(for: controlShiftSpace) == "⌃⇧Space")
    #expect(ShortcutRecorder.displayText(for: KeyCombination(key: try key("f13"))) == "F13")
    #expect(ShortcutRecorder.displayText(for: nil) == "未設定")
  }

  @Test("REC-01: 受け付けない理由の文言はすべて空でなく、互いに異なる")
  func issueMessages() {
    let issues: [ShortcutRecordingIssue] = [
      .modifierOnly, .functionModifier, .unsupportedKey, .missingModifier, .reservedForCancel,
      .conflictsWithSystemShortcut,
    ]
    let messages = issues.map(\.message)

    #expect(messages.allSatisfy { !$0.isEmpty })
    #expect(Set(messages).count == issues.count)
  }
}
