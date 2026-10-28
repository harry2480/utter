import Testing
import UtterCore
import UtterPersistence

/// 録音と Edit Mode のショートカットを1つの登録者で登録したときに、utter の中で同じ組み合わせを二重に登録しないか
/// （REC-02, AC-14）。
///
/// RegisterEventHotKey は同じプロセスの中の二重登録にも eventHotKeyExistsErr を返し（CarbonEventsCore.h）、
/// utter はそれを「他のアプリ」との競合として表示する。Stub の登録者で二重登録を断り、その回数を数えて確かめる。
@MainActor
struct ShortcutAssignmentsTests {
  /// アプリと同じ結線（`ShortcutCoordinator` と `ShortcutAssignments.connect`）を、二重登録を断る Stub の登録者で組み立てる
  @MainActor
  final class Rig {
    let registrar = StubHotKeyRegistrar()
    let shortcuts: ShortcutCoordinator
    let editMode: EditModeShortcut
    private(set) var assignments: ShortcutAssignments!
    private let phase = PhaseBox()

    /// 起動時と同じ順で登録する（録音を `ShortcutCoordinator` の作成時に登録し、Edit Mode を後から送る）
    init(recording: KeyCombination?, editMode edit: KeyCombination?) {
      registrar.rejectsDuplicates = true
      let initial = AppSettings(recordingShortcut: recording, editModeShortcut: edit)
      let phase = phase
      shortcuts = ShortcutCoordinator(
        setting: GlobalShortcutSetting.fromSettings(initial), registrar: registrar,
        currentPhase: { phase.value }, perform: { _ in },
        tapFactory: StubKeyEventTapFactory(), permissions: StubEventTapPermissions(),
        systemShortcuts: { [] })
      editMode = EditModeShortcut(registrar: registrar, systemShortcuts: { [] }, onPress: {})
      assignments = ShortcutAssignments.connect(
        recording: shortcuts, editMode: editMode, initial: initial)
    }

    var recordingStatus: GlobalShortcutStatus { shortcuts.status }

    /// 設定画面で保存したときと同じく、保存された設定から両方の割当をまとめて送る（設定の変更の通知と同じ経路）
    func save(recording: KeyCombination?, editMode edit: KeyCombination?) {
      assignments.update(from: AppSettings(recordingShortcut: recording, editModeShortcut: edit))
    }

    func startSession() {
      phase.value = .recording
    }

    /// セッションが終わって待機に戻る（認識の完了などショートカット以外の要因で戻ったとき）
    func finishSession() {
      phase.value = .idle
      shortcuts.sessionPhaseDidChange()
    }

    /// 保存された設定から作る録音の割当（操作方式などは既定値）
    static func setting(_ combination: KeyCombination) -> GlobalShortcutSetting {
      GlobalShortcutSetting.fromSettings(AppSettings(recordingShortcut: combination))!
    }
  }

  /// セッションの状態。テストから変える
  @MainActor
  final class PhaseBox {
    var value: SessionPhase = .idle
  }

  private static func combination(_ text: String) throws -> KeyCombination {
    try #require(ShortcutNotation.parse(text))
  }

  @Test("REC-02, AC-14: 以前の順序（録音を先に登録し直す）では、入れ替えると Edit Mode の組み合わせを二重に登録していた")
  func recordingFirstOrderDoubleRegisters() throws {
    // ShortcutAssignments を使わず、録音の通知 → Edit Mode の通知の順に送っていたときの再現
    let harness = Harness()
    harness.registrar.rejectsDuplicates = true
    let editMode = EditModeShortcut(
      registrar: harness.registrar, systemShortcuts: { [] }, onPress: {})
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    harness.controller.apply(Rig.setting(a))
    editMode.apply(b, recordingShortcut: a, heldByRecording: nil)

    harness.controller.update(Rig.setting(b))
    editMode.apply(a, recordingShortcut: b, heldByRecording: nil)

    #expect(harness.registrar.duplicateAttempts == 1)
    #expect(
      harness.controller.status
        == .unavailable(Rig.setting(b), .registrationFailed(.alreadyRegistered)))
    #expect(GlobalShortcutStatusText.text(for: harness.controller.status).contains("他のアプリ"))
  }

  @Test("REC-02, AC-14: 待機中に録音と Edit Mode を入れ替えても二重に登録せず、両方を登録する")
  func swapWhileIdle() throws {
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    let rig = Rig(recording: a, editMode: b)

    rig.save(recording: b, editMode: a)

    #expect(rig.registrar.duplicateAttempts == 0)
    #expect(rig.recordingStatus == .active(Rig.setting(b)))
    #expect(rig.editMode.status == .active(a))
    #expect(rig.registrar.registered.count == 2)
  }

  @Test("REC-02, AC-14: 録音を Edit Mode が使っていた組み合わせに変えても、Edit Mode が先に手放す")
  func recordingTakesEditModeCombination() throws {
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    let c = try Self.combination("ctrl+option+c")
    let rig = Rig(recording: a, editMode: b)

    rig.save(recording: b, editMode: c)

    #expect(rig.registrar.duplicateAttempts == 0)
    #expect(rig.recordingStatus == .active(Rig.setting(b)))
    #expect(rig.editMode.status == .active(c))
  }

  @Test("REC-02, AC-14: 保存された割当が同じ組み合わせでも（設定ファイルの直接の書き換えなど）、録音だけを登録する")
  func sameSavedCombination() throws {
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")

    // 起動時
    let rig = Rig(recording: a, editMode: a)
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
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    let rig = Rig(recording: a, editMode: b)

    rig.startSession()
    rig.save(recording: b, editMode: a)
    // 録音は待機に戻るまで a を登録したまま。Edit Mode は a を登録しない
    #expect(rig.shortcuts.registeredCombination == a)
    #expect(rig.editMode.status == .unavailable(a, .waitingForRecordingRelease))
    #expect(rig.editMode.status.text.contains("録音の終了後に使えます"))

    rig.finishSession()

    #expect(rig.registrar.duplicateAttempts == 0)
    #expect(rig.recordingStatus == .active(Rig.setting(b)))
    #expect(rig.editMode.status == .active(a))
  }

  @Test("REC-02, AC-14: セッション中に Edit Mode だけを録音がまだ持つ組み合わせに変えても、二重に登録しない")
  func editModeTakesHeldCombinationDuringSession() throws {
    let a = try Self.combination("ctrl+option+a")
    let b = try Self.combination("ctrl+option+b")
    let c = try Self.combination("ctrl+option+c")
    let rig = Rig(recording: a, editMode: b)

    rig.startSession()
    rig.save(recording: c, editMode: b)
    rig.save(recording: c, editMode: a)
    #expect(rig.editMode.status == .unavailable(a, .waitingForRecordingRelease))

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
            let rig = Rig(recording: start.0, editMode: start.1)
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
