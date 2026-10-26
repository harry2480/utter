import SwiftUI

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 部品の組み立ては `AppComposition`、セッションの進行は `SessionCoordinator` が持つ。
///
/// 機能ごとの画面（`Scene`）とメニューの項目は、機能のディレクトリ（`Sources/<機能>/`）に置き、
/// ここと `AppMenu` には1機能1行で並べるだけにする。複数の PR が同じ行を書き換えないようにするため。
/// アプリ全体で1つずつ持つ部品（`AppComposition`）は、ここで持って `.environment` で渡す。
@main
struct UtterApp: App {
  @State private var composition = AppComposition()

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      AppMenu()
        .environment(composition)
    }
    // 機能ごとの画面。1機能1行で、関係する機能の近くに足す
    ConsentSettingsScene()
  }
}
