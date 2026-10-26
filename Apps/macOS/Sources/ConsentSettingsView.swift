import SwiftUI
import UtterCore

/// クラウド送信の同意の画面（AC-06, AI-04, CTX-03）。表示と操作の受け渡しだけを持つ。
struct ConsentSettingsView: View {
  @Bindable var model: ConsentSettingsModel

  var body: some View {
    Form {
      Section {
        Text(ConsentScreenState.summary)
          .fixedSize(horizontal: false, vertical: true)
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
    .formStyle(.grouped)
    .frame(minWidth: 480, minHeight: 520)
    .onAppear { model.reload() }
  }
}
