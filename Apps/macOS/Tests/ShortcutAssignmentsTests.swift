import Testing
import UtterCore

/// 録音と Edit Mode のショートカットを1つの登録者で登録したときに、utter の中で同じ組み合わせを二重に登録しないか
/// （REC-02, AC-14）。
///
/// RegisterEventHotKey は同じプロセスの中の二重登録にも eventHotKeyExistsErr を返し（CarbonEventsCore.h）、
/// utter はそれを「他のアプリ」との競合として表示する。Stub の登録者で二重登録を断り、その回数を数えて確かめる。
@MainActor
struct ShortcutAssignmentsTests {
  /// 録音のコントローラー・Edit Mode・`ShortcutAssignments` を、二重登録を断る同じ Stub の登録者で組み立てる
  @MainActor
  final class Rig {
    let harness = Harness()
    let editMode: EditModeShortcut
    let assignments: ShortcutAssignments

    init() {
      harness.registrar.rejectsDuplicates = true
      editMode = EditModeShortcut(
        registrar: harness.registrar, systemShortcuts: { [] }, onPress: {})
      let controller: GlobalShortcutController = harness.controller
      assignments = ShortcutAssignments(
        editMode: editMode,
        updateRecording: { controller.update($0) },
        heldByRecording: { controller.registeredCombination })
      controller.onStatusChange = { [weak assignments] in
        assignments?.recordingRegistrationDidChange()
      }
    }

    var registrar: StubHotKeyRegistrar { harness.registrar }
    var recordingStatus: GlobalShortcutStatus { harness.controller.status }

    /// 起動時と同じ順で登録する（録音を先に登録し、Edit Mode を後から送る）
    func launch(recording: KeyCombination?, editMode edit: KeyCombination?) {
      harness.controller.apply(recording.map(Self.setting))
      assignments.update(recording: recording.map(Self.setting), editModeShortcut: edit)
    }

    /// 設定画面で保存したときと同じく、両方の割当をまとめて送る
    func save(recording: KeyCombination?, editMode edit: KeyCombination?) {
      assignments.update(recording: recording.map(Self.setting), editModeShortcut: edit)
    }

    func startSession() {
      harness.phase = .recording
    }

    /// セッションが終わって待機に戻る（認識の完了などショートカット以外の要因で戻ったとき）
    func finishSession() {
      harness.phase = .idle
      harness.controller.sessionPhaseDidChange()
    }

    static func setting(_ combination: KeyCombination) -> GlobalShortcutSetting {
      GlobalShortcutSetting(combination: combination, mode: .toggle)
    }
  }

  private static func combination(_ text: String) throws -> KeyCombination {
    try #require(ShortcutNotation.parse(text))
  }

  @Test("REC-02, AC-14: 以前の順序（録音を先に登録し直す）では、入れ替えると Edit Mode の組み合わせを二重に登録していた")
  func recordingFirstOrderDoubleRegisters() throws {
    // ShortcutAssignments を使わず、録音の通知 → Edit Mode の通知の順に送っていたときの再現
    let rig = Rig()
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    rig.harness.controller.apply(Rig.setting(a))
    rig.editMode.apply(b, recordingShortcut: a)

    rig.harness.controller.update(Rig.setting(b))
    rig.editMode.apply(a, recordingShortcut: b)

    #expect(rig.registrar.duplicateAttempts == 1)
    #expect(
      rig.recordingStatus == .unavailable(Rig.setting(b), .registrationFailed(.alreadyRegistered)))
    #expect(GlobalShortcutStatusText.text(for: rig.recordingStatus).contains("他のアプリ"))
  }

  @Test("REC-02, AC-14: 待機中に録音と Edit Mode を入れ替えても二重に登録せず、両方を登録する")
  func swapWhileIdle() throws {
    let rig = Rig()
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    rig.launch(recording: a, editMode: b)

    rig.save(recording: b, editMode: a)

    #expect(rig.registrar.duplicateAttempts == 0)
    #expect(rig.recordingStatus == .active(Rig.setting(b)))
    #expect(rig.editMode.status == .active(a))
    #expect(rig.registrar.registered.count == 2)
  }

  @Test("REC-02, AC-14: 録音を Edit Mode が使っていた組み合わせに変えても、Edit Mode が先に手放す")
  func recordingTakesEditModeCombination() throws {
    let rig = Rig()
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    let c = try Self.combination("ctrl+option+c")
    rig.launch(recording: a, editMode: b)

    rig.save(recording: b, editMode: c)

    #expect(rig.registrar.duplicateAttempts == 0)
    #expect(rig.recordingStatus == .active(Rig.setting(b)))
    #expect(rig.editMode.status == .active(c))
  }

  @Test("REC-02, AC-14: 保存された割当が同じ組み合わせでも（設定ファイルの直接の書き換えなど）、録音だけを登録する")
  func sameSavedCombination() throws {
    let rig = Rig()
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")

    // 起動時
    rig.launch(recording: a, editMode: a)
    #expect(rig.recordingStatus == .active(Rig.setting(a)))
    #expect(rig.editMode.status == .unavailable(a, .sameAsRecording))

    // Edit Mode を先に登録した状態で、録音を同じ組み合わせに変える
    rig.save(recording: a, editMode: b)
    #expect(rig.editMode.status == .active(b))
    rig.save(recording: b, editMode: b)

    #expect(rig.registrar.duplicateAttempts == 0)
    #expect(rig.recordingStatus == .active(Rig.setting(b)))
    #expect(rig.editMode.status == .unavailable(b, .sameAsRecording))
  }

  @Test("REC-02, AC-14: セッション中に入れ替えると、録音が前の組み合わせを持つ間は Edit Mode を待たせ、待機に戻ってから両方を登録する")
  func swapDuringSession() throws {
    let rig = Rig()
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    rig.launch(recording: a, editMode: b)

    rig.startSession()
    rig.save(recording: b, editMode: a)
    // 録音は待機に戻るまで a を登録したまま。Edit Mode は a を登録しない
    #expect(rig.harness.controller.registeredCombination == a)
    #expect(rig.editMode.status == .unavailable(a, .sameAsRecording))

    rig.finishSession()

    #expect(rig.registrar.duplicateAttempts == 0)
    #expect(rig.recordingStatus == .active(Rig.setting(b)))
    #expect(rig.editMode.status == .active(a))
  }

  @Test("REC-02, AC-14: セッション中に Edit Mode だけを録音がまだ持つ組み合わせに変えても、二重に登録しない")
  func editModeTakesHeldCombinationDuringSession() throws {
    let rig = Rig()
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    let c = try Self.combination("ctrl+option+c")
    rig.launch(recording: a, editMode: b)

    rig.startSession()
    rig.save(recording: c, editMode: b)
    rig.save(recording: c, editMode: a)
    #expect(rig.editMode.status == .unavailable(a, .sameAsRecording))

    rig.finishSession()

    #expect(rig.registrar.duplicateAttempts == 0)
    #expect(rig.recordingStatus == .active(Rig.setting(c)))
    #expect(rig.editMode.status == .active(a))
  }

  @Test("REC-02, AC-14: 割当の組み合わせと順序（待機中・セッション中）をすべて試しても、二重に登録しない")
  func exhaustiveTransitions() throws {
    let keys: [KeyCombination?] = [
      nil, try Self.combination("ctrl+option+a"), try Self.combination("ctrl+option+b"),
      try Self.combination("ctrl+option+c"),
    ]
    let states = keys.flatMap { recording in keys.map { (recording, $0) } }
    for start in states {
      for first in states {
        for second in states {
          for duringSession in [false, true] {
            let rig = Rig()
            rig.launch(recording: start.0, editMode: start.1)
            if duringSession { rig.startSession() }
            rig.save(recording: first.0, editMode: first.1)
            rig.save(recording: second.0, editMode: second.1)
            if duringSession { rig.finishSession() }

            let label = "\(start) → \(first) → \(second), session: \(duringSession)"
            #expect(rig.registrar.duplicateAttempts == 0, "\(label)")
            let expectedRecording: GlobalShortcutStatus =
              second.0.map { .active(Rig.setting($0)) } ?? .unassigned
            #expect(rig.recordingStatus == expectedRecording, "\(label)")
            let expectedEditMode: EditModeShortcutStatus =
              switch second.1 {
              case nil: .unassigned
              case let edit? where edit == second.0: .unavailable(edit, .sameAsRecording)
              case let edit?: .active(edit)
              }
            #expect(rig.editMode.status == expectedEditMode, "\(label)")
          }
        }
      }
    }
  }
}
