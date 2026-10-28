import SwiftUI
import UtterCore
import UtterPersistence

/// メニューの先頭に出すセッションの状態（待機中・録音中など, #197）
struct SessionStatusMenuItem: View {
  @Environment(AppComposition.self) private var composition

  var body: some View {
    Text(MenuBarModel.phaseTitle(composition.session.phase))
  }
}

/// メニューの入力モード・文体・整形の実行先の切り替えと、認識モデルの状態・今月の推定費用（#197）。
///
/// 表示と保存は `MenuBarModel` が持ち、ここは並べるだけにする。保存先は設定画面と同じ。
/// 同意のない送信先を選んだら同意の画面を開く（同意がない間は送らない, AC-06）
struct MenuBarSwitchItems: View {
  @Environment(MenuBarModel.self) private var model
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let settings = model.settings
    Menu("入力モード: \(MenuBarModel.inputModeName(settings.inputMode))") {
      ForEach(model.inputModeChoices, id: \.self) { mode in
        Toggle(mode.label, isOn: binding(for: mode))
      }
    }
    Menu("文体: \(MenuBarModel.refinementModeName(settings.refinementMode))") {
      ForEach(RefinementModeSetting.allCases, id: \.self) { mode in
        Toggle(mode.label, isOn: binding(for: mode))
      }
    }
    if let app = model.frontmostApp {
      Text("\(app.name) の自動スタイル: \(model.autoStyle(forBundleID: app.bundleID).label)")
    }
    Menu("整形の実行先: \(MenuBarModel.providerName(model.provider))") {
      ForEach(RefinementProviderChoice.allCases) { choice in
        Toggle(title(of: choice), isOn: binding(for: choice))
          .disabled(!choice.isSelectable)
      }
    }
    if model.saveFailed {
      Text("設定を保存できませんでした")
    }
    let speechRecognition = MenuBarModel.speechRecognitionText(
      engine: model.sttEngine, cloudEnabled: settings.cloudSpeechRecognitionEnabled,
      availability: model.speechModelAvailability)
    Text(speechRecognition)
    Text(MenuBarModel.costText(model.cost))
    if case .summary = model.cost {
      Text(MenuBarModel.costEstimateNote)
    }
  }

  private func binding(for mode: InputMode) -> Binding<Bool> {
    Binding(
      get: { model.settings.inputMode == mode },
      set: { _ in _ = model.select(inputMode: mode) })
  }

  private func binding(for mode: RefinementModeSetting) -> Binding<Bool> {
    Binding(
      get: { model.settings.refinementMode == mode },
      set: { _ in _ = model.select(refinementMode: mode) })
  }

  private func binding(for choice: RefinementProviderChoice) -> Binding<Bool> {
    Binding(
      get: { model.provider == choice },
      set: { _ in select(choice) })
  }

  private func title(of choice: RefinementProviderChoice) -> String {
    MenuBarModel.providerTitle(choice, hasConsent: model.hasConsent(for: choice))
  }

  private func select(_ choice: RefinementProviderChoice) {
    switch model.select(provider: choice) {
    case .consentRequired:
      // 同意の画面へ案内する。同意はその画面で利用者が行う
      openWindow(id: ConsentSettingsScene.windowID)
      bringToFront()
    case .saved, .notSelectable, .saveFailed:
      break
    }
  }
}
