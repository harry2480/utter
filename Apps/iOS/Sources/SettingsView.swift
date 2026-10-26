import SwiftUI
import UtterAI
import UtteriOSKit

/// 設定の入口（iOS-10）。音声認識・整形と予算・クラウド送信の同意・Claude API キーの画面へ移る。
struct SettingsView: View {
  let refinementSettings: RefinementSettingsModel
  let consentSettings: ConsentSettingsModel
  let claudeAPIKeySettings: APIKeySettingsModel
  let speechEngine: SpeechEngineSelection
  /// 取得できるモデルがあるエンジンのときだけ
  let speechModel: SpeechModelSettingsModel?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          NavigationLink("音声認識の設定") {
            SpeechSettingsView(engine: speechEngine, model: speechModel)
          }
        }
        Section {
          NavigationLink("整形と予算") {
            RefinementSettingsView(model: refinementSettings)
          }
          NavigationLink("クラウド送信の同意") {
            ConsentSettingsView(model: consentSettings)
          }
          NavigationLink("Claude API キー") {
            ClaudeAPIKeySettingsView(model: claudeAPIKeySettings)
          }
        } footer: {
          Text(
            "Claude による整形は、整形の処理系にクラウド AI を選び、送信に同意し、API キーと月次予算・単価表を設定したときだけ使います。それ以外は端末内の整形（Local Basic）を使います。"
          )
        }
      }
      .navigationTitle("設定")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完了") { dismiss() }
        }
      }
    }
  }
}
