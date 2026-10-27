import Testing
import UtterCore

/// Edit Mode のショートカットの登録（AC-14）。OS には登録せず、Stub の登録者で確かめる。
@MainActor
struct EditModeShortcutTests {
  let registrar = StubHotKeyRegistrar()

  private func shortcut(
    systemShortcuts: [ShortcutBinding] = [], onPress: @escaping @MainActor () -> Void = {}
  ) -> EditModeShortcut {
    EditModeShortcut(
      registrar: registrar, systemShortcuts: { systemShortcuts }, onPress: onPress)
  }

  private func combination(_ text: String) throws -> KeyCombination {
    try #require(ShortcutNotation.parse(text))
  }

  @Test("AC-14: 未割り当て（既定）なら何も登録しない")
  func unassignedRegistersNothing() throws {
    let editMode = shortcut()

    let recording = try combination("option+cmd+r")
    #expect(editMode.apply(nil, recordingShortcut: recording) == .unassigned)
    #expect(registrar.registered.isEmpty)
  }

  @Test("AC-14: 割り当てると登録し、押下でだけ始める（解放では何もしない）")
  func pressTriggersOnce() throws {
    let presses = PressCounter()
    let editMode = shortcut(onPress: { presses.count += 1 })
    let edit = try combination("option+cmd+e")

    let recording = try combination("option+cmd+r")
    #expect(editMode.apply(edit, recordingShortcut: recording) == .active(edit))
    #expect(registrar.registered.count == 1)

    registrar.send(.pressed)
    registrar.send(.released)
    #expect(presses.count == 1)
  }

  @Test("AC-14: 録音ショートカットと同じキーは登録しない")
  func sameAsRecordingIsRejected() throws {
    let editMode = shortcut()
    let key = try combination("option+cmd+r")

    #expect(editMode.apply(key, recordingShortcut: key) == .unavailable(key, .sameAsRecording))
    #expect(registrar.registered.isEmpty)
  }

  @Test("AC-14, REC-02: Esc・修飾キーなしのキー・システムのショートカットと重なるキーは登録しない")
  func invalidShortcutsAreRejected() throws {
    let spotlight = try combination("cmd+space")
    let editMode = shortcut(
      systemShortcuts: [ShortcutBinding(id: "system.spotlight", combination: spotlight)])

    #expect(
      editMode.apply(.escape, recordingShortcut: nil)
        == .unavailable(.escape, .invalid([.reservedForCancel])))
    let space = KeyCombination(key: .space)
    #expect(
      editMode.apply(space, recordingShortcut: nil)
        == .unavailable(space, .unsupported(.missingModifier)))
    #expect(
      editMode.apply(spotlight, recordingShortcut: nil)
        == .unavailable(
          spotlight, .invalid([.conflict(bindingID: "system.spotlight", kind: .identical)])))
    #expect(registrar.registered.isEmpty)
  }

  @Test("AC-14: 割当を変えると前の登録を外し、解除すると何も登録しない。同じ割当なら登録し直さない")
  func reassignment() throws {
    let editMode = shortcut()
    let recording = try combination("option+cmd+r")
    let first = try combination("option+cmd+e")
    let second = try combination("ctrl+cmd+e")

    editMode.apply(first, recordingShortcut: recording)
    editMode.apply(first, recordingShortcut: recording)
    #expect(registrar.unregisteredIDs.isEmpty)

    #expect(editMode.apply(second, recordingShortcut: recording) == .active(second))
    #expect(registrar.unregisteredIDs.count == 1)
    #expect(registrar.registered.count == 1)

    #expect(editMode.apply(nil, recordingShortcut: recording) == .unassigned)
    #expect(registrar.registered.isEmpty)
  }

  @Test("AC-14: 登録に失敗したら理由を残す")
  func registrationFailure() throws {
    let editMode = shortcut()
    let key = try combination("option+cmd+e")
    registrar.nextFailure = .alreadyRegistered

    #expect(
      editMode.apply(key, recordingShortcut: nil)
        == .unavailable(key, .registrationFailed(.alreadyRegistered)))
  }
}

/// ショートカットの押下の回数
@MainActor
private final class PressCounter {
  var count = 0
}
