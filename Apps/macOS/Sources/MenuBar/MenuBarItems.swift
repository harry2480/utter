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
    MenuSection(title: "入力モード") {
      Picker("入力モード", selection: inputModeSelection) {
        ForEach(model.inputModeChoices, id: \.self) { mode in
          Text(MenuBarModel.inputModeName(mode)).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
    MenuSection(title: "文体") {
      Picker("文体", selection: refinementModeSelection) {
        ForEach(RefinementModeSetting.allCases, id: \.self) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      if let app = model.frontmostApp {
        Text("\(app.name) の自動スタイル: \(model.autoStyle(forBundleID: app.bundleID).label)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    MenuSection(title: "整形の実行先") {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(RefinementProviderChoice.allCases) { choice in
          Button {
            select(choice)
          } label: {
            HStack(spacing: 8) {
              Image(systemName: model.provider == choice ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(model.provider == choice ? UtterTheme.accent : Color.secondary)
              Text(title(of: choice))
              Spacer(minLength: 0)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(model.provider == choice ? .isSelected : [])
        }
      }
      if model.saveFailed {
        Text("設定を保存できませんでした")
          .font(.caption)
          .foregroundStyle(UtterTheme.warningText)
      }
    }
    let speechRecognition = MenuBarModel.speechRecognitionText(
      engine: model.sttEngine, cloudEnabled: settings.cloudSpeechRecognitionEnabled,
      availability: model.speechModelAvailability)
    MenuSection(title: nil) {
      Text(speechRecognition)
      Text(MenuBarModel.costText(model.cost))
      if case .summary = model.cost {
        Text(MenuBarModel.costEstimateNote)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var inputModeSelection: Binding<InputMode> {
    Binding(
      get: { model.settings.inputMode },
      set: { _ = model.select(inputMode: $0) })
  }

  private var refinementModeSelection: Binding<RefinementModeSetting> {
    Binding(
      get: { model.settings.refinementMode },
      set: { _ = model.select(refinementMode: $0) })
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
    case .saved, .saveFailed:
      break
    }
  }
}

/// メニューの区切り。見出しと、その下の内容
struct MenuSection<Content: View>: View {
  let title: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title {
        Text(title)
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
