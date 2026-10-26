#if DEBUG
  import SwiftUI

  /// メニューの HUD のデモ（Debug ビルドのみ）。状態機械を進めて HUD の表示を目視で確かめる
  struct HUDDemoMenuItem: View {
    let demo: HUDDemo

    var body: some View {
      Button("HUD のデモ（上限到達）") {
        demo.runLimitReached()
      }
      Button("HUD のデモ（失敗）") {
        demo.runFailure()
      }
    }
  }
#endif
