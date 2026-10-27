import SwiftUI

/// メニューの Edit Mode（AC-14）の状態と、「Edit をキャンセル」「直前の Edit を元に戻す」。
///
/// Edit はショートカットからだけ始める（選択範囲のある入力欄のフォーカスを保つため）。ショートカットが未割り当て（既定）の間は
/// 状態だけを出す。`Sources/EditMode` はテスト・バンドル `UtterMacTests` にソースごと含めるため、画面の部品はここに分ける。
struct EditModeMenuItems: View {
  @Environment(AppComposition.self) private var composition

  var body: some View {
    let editMode = composition.editMode
    Text(composition.editModeShortcut.status.text)
    if editMode.canCancel {
      Button("Edit をキャンセル") {
        editMode.cancel()
      }
    }
    if editMode.canUndo {
      Button("直前の Edit を元に戻す") {
        Task { await editMode.undo() }
      }
      .disabled(editMode.phase != .idle)
    }
  }
}
