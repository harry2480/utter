import SwiftUI

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
///
/// 機能ごとの画面（`Scene`）とメニューの項目は、機能のディレクトリ（`Sources/<機能>/`）に置き、
/// ここと `AppMenu` には1機能1行で並べるだけにする。複数の PR が同じ行を書き換えないようにするため。
@main
struct UtterApp: App {
  /// 録音ショートカットの登録。起動時から終了まで保持し、メニューの表示にも使う
  @State private var shortcuts = ShortcutCoordinator()

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      AppMenu()
        .environment(shortcuts)
    }
    // 機能ごとの画面。1機能1行で、関係する機能の近くに足す
    ConsentSettingsScene()
  }
}
