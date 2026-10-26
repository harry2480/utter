import Testing

@testable import UtterCore

struct ShortcutValidatorTests {
  let space = KeyCombination(key: .space, modifiers: [.option])
  let fnOnly = KeyCombination(modifierOnly: [.function])
  let supported = ShortcutValidator(
    capabilities: ShortcutCapabilities(supportsModifierOnly: true, supportsEscapeCapture: false))
  let unsupported = ShortcutValidator(
    capabilities: .keyCombinationsOnly)

  @Test("REC-02: 通常のキー組み合わせだけの範囲は、修飾キー単独・Esc 捕捉とも使わない（#51 の判定待ち）")
  func keyCombinationsOnly() {
    #expect(!ShortcutCapabilities.keyCombinationsOnly.supportsModifierOnly)
    #expect(!ShortcutCapabilities.keyCombinationsOnly.supportsEscapeCapture)
  }

  @Test("REC-02: キー名は前後の空白を除いて小文字にそろえ、空の名前は作れない")
  func normalizesKeyName() throws {
    let key = try #require(ShortcutKey(rawValue: " Space\n"))
    #expect(key == .space)
    #expect(ShortcutKey(rawValue: "  ") == nil)
    #expect(ShortcutKey(rawValue: "") == nil)
  }

  @Test("REC-02: 修飾キー単独の組み合わせは修飾キーが空では作れない")
  func modifierOnlyRequiresModifiers() throws {
    #expect(KeyCombination(modifierOnly: []) == nil)
    let combination = try #require(fnOnly)
    #expect(combination.isModifierOnly)
    #expect(!space.isModifierOnly)
  }

  @Test("REC-02: 登録済みの割当と競合しなければ問題なし")
  func acceptsUniqueCombination() {
    let registered = [
      ShortcutBinding(
        id: "system.spotlight", combination: KeyCombination(key: .space, modifiers: [.command]))
    ]

    #expect(
      unsupported.issues(for: space, bindingID: "utter.record", registered: registered).isEmpty)
  }

  @Test("REC-02: 同じ組み合わせの割当を競合として検出する")
  func detectsIdenticalConflict() {
    let registered = [
      ShortcutBinding(
        id: "other.app", combination: KeyCombination(key: .space, modifiers: [.option]))
    ]

    let issues = unsupported.issues(for: space, bindingID: "utter.record", registered: registered)

    #expect(issues == [.conflict(bindingID: "other.app", kind: .identical)])
  }

  @Test("REC-02: 修飾キーの順序や指定の仕方が違っても同じ組み合わせとみなす")
  func modifierOrderDoesNotMatter() throws {
    let lhs = KeyCombination(
      key: try #require(ShortcutKey(rawValue: "A")), modifiers: [.command, .shift])
    let rhs = KeyCombination(
      key: try #require(ShortcutKey(rawValue: "a")), modifiers: [.shift, .command])

    #expect(ShortcutValidator.conflictKind(lhs, rhs) == .identical)
  }

  @Test("REC-02: 自分自身の既存の割当とは比較しない")
  func ignoresOwnBinding() {
    let registered = [ShortcutBinding(id: "utter.record", combination: space)]

    #expect(
      unsupported.issues(for: space, bindingID: "utter.record", registered: registered).isEmpty)
  }

  @Test("REC-02: 修飾キー単独と、その修飾キーを含む組み合わせを重複として検出する")
  func detectsModifierOverlap() throws {
    let fn = try #require(fnOnly)
    let fnA = KeyCombination(key: try #require(ShortcutKey(rawValue: "a")), modifiers: [.function])
    let fnShift = try #require(KeyCombination(modifierOnly: [.function, .shift]))
    let optionSpace = space

    #expect(ShortcutValidator.conflictKind(fn, fnA) == .modifierOverlap)
    #expect(ShortcutValidator.conflictKind(fnA, fn) == .modifierOverlap)
    #expect(ShortcutValidator.conflictKind(fn, fnShift) == .modifierOverlap)
    #expect(ShortcutValidator.conflictKind(fn, optionSpace) == nil)
    #expect(ShortcutValidator.conflictKind(space, fnA) == nil)
  }

  @Test("REC-02: 修飾キー単独は対応可否の設定に従う")
  func modifierOnlyFollowsCapabilities() throws {
    let fn = try #require(fnOnly)

    #expect(
      unsupported.issues(for: fn, bindingID: "utter.record", registered: []) == [
        .modifierOnlyUnsupported
      ])
    #expect(supported.issues(for: fn, bindingID: "utter.record", registered: []).isEmpty)
  }

  @Test("REC-01: 修飾キーなしの Esc はキャンセルに予約されている")
  func escapeIsReserved() {
    #expect(
      supported.issues(for: .escape, bindingID: "utter.record", registered: []) == [
        .reservedForCancel
      ])
    let shiftEscape = KeyCombination(key: .escape, modifiers: [.shift])
    #expect(supported.issues(for: shiftEscape, bindingID: "utter.record", registered: []).isEmpty)
  }

  @Test("REC-02: 複数の問題をまとめて返す")
  func reportsAllIssues() throws {
    let fn = try #require(fnOnly)
    let registered = [
      ShortcutBinding(id: "a", combination: fn),
      ShortcutBinding(
        id: "b", combination: KeyCombination(key: .space, modifiers: [.function, .command])),
      ShortcutBinding(id: "c", combination: space),
    ]

    let issues = unsupported.issues(for: fn, bindingID: "utter.record", registered: registered)

    #expect(
      issues == [
        .modifierOnlyUnsupported,
        .conflict(bindingID: "a", kind: .identical),
        .conflict(bindingID: "b", kind: .modifierOverlap),
      ])
  }
}
