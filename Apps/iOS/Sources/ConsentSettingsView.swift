import SwiftUI
import UtterCore
import UtteriOSKit

/// iOS のクラウド送信の同意の画面（iOS-10, AC-06, AI-04, CTX-03）。表示と操作の受け渡しだけを持つ。
///
/// 文言と行は macOS と同じ `ConsentScreenState` / `ConsentDisclosure` から作る。
struct ConsentSettingsView: View {
  @Bindable var model: ConsentSettingsModel

  var body: some View {
    Form {
      Section {
        Text(ConsentScreenState.summary)
        if model.saveFailed {
          Text("同意の状態を保存できませんでした。もう一度操作してください。")
            .foregroundStyle(.red)
        }
      }
      ForEach(model.screen.rows) { row in
        Section {
          Toggle(
            isOn: Binding(
              get: { row.isGranted },
              set: { model.setGranted($0, for: row.scope) })
          ) {
            Text(row.disclosure.title).font(.headline)
            Text(row.statusLabel)
          }
          LabeledContent("送る内容", value: row.disclosure.content)
          LabeledContent("送信先", value: row.disclosure.destination)
          LabeledContent(
            "送らないもの", value: row.disclosure.notSent.joined(separator: "、"))
          if let note = row.disclosure.note {
            Text(note).font(.footnote).foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle("クラウド送信の同意")
    .onAppear { model.reload() }
  }
}
