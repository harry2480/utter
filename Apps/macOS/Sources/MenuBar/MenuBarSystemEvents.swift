import AppKit
import Foundation
import UtterPersistence

extension MenuBarModel {
  /// アプリで使うメニューの状態。設定画面と同じ保存先（UserDefaults.standard）とデータベースを使う。
  ///
  /// 作ったときと、設定の保存・メニューを開いたとき・前面のアプリが変わったときに読み直す（`followSystemEvents()`）
  static func standard(database: AppDatabaseProvider) -> MenuBarModel {
    let engine = AppComposition.selectedEngine()
    let model = MenuBarModel(
      store: AppSettingsStore(defaults: .standard),
      openUsageStore: { MonthlyUsageStore(database: try await database.database()) },
      sttEngine: engine, modelAssets: STTEngineSetting.makeModelAssets(for: engine))
    model.updateFrontmostApp(Self.frontmostApp(of: NSWorkspace.shared.frontmostApplication))
    model.followSystemEvents()
    Task {
      await model.refreshCost()
      await model.refreshSpeechModel()
    }
    return model
  }

  /// 設定の保存・メニューを開く・前面のアプリの切り替えを受けて読み直す。アプリの終了まで続ける
  private func followSystemEvents() {
    // 設定画面・同意の画面・メニューの保存は UserDefaults の変更の通知で受ける（`AppComposition` と同じ）。
    // アプリの終了まで登録したままにするため、戻り値（登録の解除に使う）は持たない
    _ = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.reload() else { return }
        Task { await self.refreshCost() }
      }
    }
    // 推定費用の累計は整形のたびにデータベースへ加算されるため、メニューを開くたびに読み直す
    _ = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        Task {
          await self.refreshCost()
          await self.refreshSpeechModel()
        }
      }
    }
    // 自動スタイルを出す前面のアプリ。utter 自身（設定画面など）が前面になったときは、直前のアプリのままにする
    _ = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let app = NSWorkspace.shared.frontmostApplication,
          app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        self.updateFrontmostApp(Self.frontmostApp(of: app))
      }
    }
  }

  /// 表示に使う前面のアプリ。utter 自身・分からなければ `nil`
  private static func frontmostApp(of app: NSRunningApplication?) -> FrontmostApp? {
    guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
    let name = app.localizedName ?? app.bundleIdentifier ?? "前面のアプリ"
    return FrontmostApp(bundleID: app.bundleIdentifier, name: name)
  }
}
