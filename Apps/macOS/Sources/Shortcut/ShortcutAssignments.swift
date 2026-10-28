import UtterCore

/// 録音と Edit Mode のショートカットを、utter の中で同じ組み合わせを二重に登録しない順序で登録し直す（REC-02, AC-14）。
///
/// RegisterEventHotKey は、同じプロセスの中で登録済みの組み合わせを登録したときにも eventHotKeyExistsErr を返す
/// （CarbonEventsCore.h）。録音と Edit Mode の割当を入れ替えたとき（録音 A・Edit B → 録音 B・Edit A）に録音を先に
/// 登録し直すと、Edit Mode がまだ登録している B を二重に登録して失敗し、「他のアプリ」との競合として表示してしまう。
/// また、セッション中に録音の割当が変わると、録音は待機に戻るまで前の組み合わせを登録したままにする。そのため次の順で送る:
///
/// 1. Edit Mode が録音の新しい割当を登録していれば、録音より先に登録し直して手放させる
/// 2. 録音を登録し直す（セッション中なら待機に戻ってから。`GlobalShortcutController.update(_:)`）
/// 3. Edit Mode を、録音の割当と録音がいま登録している組み合わせの両方を避けて登録し直す
///
/// 録音が待機に戻ってから登録し直したときは `recordingRegistrationDidChange()` で 3 をやり直す。
@MainActor
final class ShortcutAssignments {
  private let editMode: EditModeShortcut
  private let updateRecording: @MainActor (GlobalShortcutSetting?) -> Void
  private let heldByRecording: @MainActor () -> KeyCombination?
  private var recording: GlobalShortcutSetting?
  private var editModeShortcut: KeyCombination?

  /// - Parameters:
  ///   - editMode: Edit Mode のショートカットの登録
  ///   - updateRecording: 録音の割当を送る（`ShortcutCoordinator.updateSetting(_:)`）
  ///   - heldByRecording: 録音がいま登録している組み合わせ（`ShortcutCoordinator.registeredCombination`）
  init(
    editMode: EditModeShortcut,
    updateRecording: @escaping @MainActor (GlobalShortcutSetting?) -> Void,
    heldByRecording: @escaping @MainActor () -> KeyCombination?
  ) {
    self.editMode = editMode
    self.updateRecording = updateRecording
    self.heldByRecording = heldByRecording
  }

  /// 保存された割当を送る。録音・Edit Mode とも、前に送った割当と同じなら登録し直さない。
  func update(recording: GlobalShortcutSetting?, editModeShortcut: KeyCombination?) {
    let recordingChanged = recording != self.recording
    self.recording = recording
    self.editModeShortcut = editModeShortcut
    if recordingChanged {
      if case .active(let held) = editMode.status, held == recording?.combination {
        applyEditMode()
      }
      updateRecording(recording)
    }
    applyEditMode()
  }

  /// 録音の登録が変わったとき（待機に戻ってから割当を登録したときなど）に呼ぶ
  func recordingRegistrationDidChange() {
    applyEditMode()
  }

  private func applyEditMode() {
    editMode.apply(
      editModeShortcut, recordingShortcut: recording?.combination,
      heldByRecording: heldByRecording())
  }
}
