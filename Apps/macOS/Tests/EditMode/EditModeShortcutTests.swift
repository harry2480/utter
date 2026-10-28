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
    #expect(editMode.apply(nil, recordingShortcut: recording, heldByRecording: nil) == .unassigned)
    #expect(registrar.registered.isEmpty)
  }

  @Test("AC-14: 割り当てると登録し、押下でだけ始める（解放では何もしない）")
  func pressTriggersOnce() throws {
    let presses = PressCounter()
    let editMode = shortcut(onPress: { presses.count += 1 })
    let edit = try combination("option+cmd+e")

    let recording = try combination("option+cmd+r")
    #expect(
      editMode.apply(edit, recordingShortcut: recording, heldByRecording: nil) == .active(edit))
    #expect(registrar.registered.count == 1)

    registrar.send(.pressed)
    registrar.send(.released)
    #expect(presses.count == 1)
  }

  @Test("AC-14: 録音ショートカットと同じキーは登録しない")
  func sameAsRecordingIsRejected() throws {
    let editMode = shortcut()
    let key = try combination("option+cmd+r")

    #expect(
      editMode.apply(key, recordingShortcut: key, heldByRecording: nil)
        == .unavailable(key, .sameAsRecording))
    #expect(registrar.registered.isEmpty)
  }

  @Test("AC-14: 録音がまだ登録している前の組み合わせは、録音の終了後に使えると出して登録しない")
  func heldByRecordingWaits() throws {
    let editMode = shortcut()
    let key = try combination("option+cmd+r")
    let recording = try combination("ctrl+cmd+r")

    #expect(
      editMode.apply(key, recordingShortcut: recording, heldByRecording: key)
        == .unavailable(key, .waitingForRecordingRelease))
    #expect(registrar.registered.isEmpty)
    #expect(editMode.status.text == "Edit Mode: \(ShortcutNotation.display(key)) は録音の終了後に使えます")

    // 保存された録音の割当と同じなら、録音がまだ持っていても「録音と同じキー」のまま
    #expect(
      editMode.apply(key, recordingShortcut: key, heldByRecording: key)
        == .unavailable(key, .sameAsRecording))
    #expect(editMode.status.text.contains("録音と同じキーのため使えません"))
  }

  @Test("AC-14, REC-02: Esc・修飾キーなしのキー・システムのショートカットと重なるキーは登録しない")
  func invalidShortcutsAreRejected() throws {
    let spotlight = try combination("cmd+space")
    let editMode = shortcut(
      systemShortcuts: [ShortcutBinding(id: "system.spotlight", combination: spotlight)])

    #expect(
      editMode.apply(.escape, recordingShortcut: nil, heldByRecording: nil)
        == .unavailable(.escape, .invalid([.reservedForCancel])))
    let space = KeyCombination(key: .space)
    #expect(
      editMode.apply(space, recordingShortcut: nil, heldByRecording: nil)
        == .unavailable(space, .unsupported(.missingModifier)))
    #expect(
      editMode.apply(spotlight, recordingShortcut: nil, heldByRecording: nil)
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

    editMode.apply(first, recordingShortcut: recording, heldByRecording: nil)
    editMode.apply(first, recordingShortcut: recording, heldByRecording: nil)
    #expect(registrar.unregisteredIDs.isEmpty)

    #expect(
      editMode.apply(second, recordingShortcut: recording, heldByRecording: nil) == .active(second))
    #expect(registrar.unregisteredIDs.count == 1)
    #expect(registrar.registered.count == 1)

    #expect(editMode.apply(nil, recordingShortcut: recording, heldByRecording: nil) == .unassigned)
    #expect(registrar.registered.isEmpty)
  }

  @Test("AC-14: 登録に失敗したら理由を残す")
  func registrationFailure() throws {
    let editMode = shortcut()
    let key = try combination("option+cmd+e")
    registrar.nextFailure = .alreadyRegistered

    #expect(
      editMode.apply(key, recordingShortcut: nil, heldByRecording: nil)
        == .unavailable(key, .registrationFailed(.alreadyRegistered)))
  }
}

/// ショートカットの押下の回数
@MainActor
private final class PressCounter {
  var count = 0
}
