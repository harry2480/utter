import SwiftUI
import UtterAI
import UtteriOSKit

/// 設定の入口（iOS-10）。クラウド送信の同意と Claude API キーの画面へ移る。
struct SettingsView: View {
  let consentSettings: ConsentSettingsModel
  let claudeAPIKeySettings: APIKeySettingsModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
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
