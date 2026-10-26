#if DEBUG
  import SwiftUI

  /// メニューの Edit Mode（AC-14, v1.1）の Debug 用の項目
  struct EditModeMenuItem: View {
    /// Edit Mode の Debug 用の組み立て。`nil` のときは Edit Mode の項目を出さない
    let editMode: EditModeDebugController?

    var body: some View {
      if let editMode {
        Button("選択範囲を指示で編集（実験・Debug）") {
          editMode.start()
        }
        Button("直前の Edit を元に戻す（実験・Debug）") {
          Task { await editMode.undo() }
        }
        Divider()
      }
    }
  }
#endif
