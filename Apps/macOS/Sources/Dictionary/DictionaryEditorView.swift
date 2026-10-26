import SwiftUI
import UtterText

/// 辞書の編集画面（TXT-03, AC-07）。編集・検証・保存は `DictionaryEditorModel` に任せ、入力欄と一覧だけを持つ。
struct DictionaryEditorView: View {
  let model: DictionaryEditorModel

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        ProgressView()
      case .failed(.unreadable):
        ContentUnavailableView(
          "辞書を読み込めませんでした", systemImage: "exclamationmark.triangle",
          description: Text("画面を開き直してください。"))
      case .failed(.inconsistent):
        ContentUnavailableView(
          "保存された辞書に矛盾があります", systemImage: "exclamationmark.triangle",
          description: Text("同じ読みに一致する置換ルールが複数保存されています。内容を上書きしないよう、編集を止めています。"))
      case .loaded(let editor):
        DictionaryEditorForm(model: model, editor: editor)
      }
    }
    .frame(minWidth: 480, minHeight: 520)
    .task { await model.load() }
  }
}

private struct DictionaryEditorForm: View {
  let model: DictionaryEditorModel
  let editor: DictionaryEditor

  @State private var termInput = ""
  @State private var editingTermIndex: Int?
  @State private var patternInput = ""
  @State private var replacementInput = ""
  @State private var ignoresCaseInput = false
  @State private var editingRuleIndex: Int?

  var body: some View {
    Form {
      Section {
        Text("辞書語は、クラウド整形（Claude / ChatGPT）を使うときに整形の文脈として送信されます。パスワードなどの秘密情報は登録しないでください。")
          .font(.callout)
          .foregroundStyle(.secondary)
        if let message = model.errorMessage {
          Text(message).foregroundStyle(.red)
        }
      }

      Section("辞書語（表記を保持する語）") {
        ForEach(Array(editor.terms.enumerated()), id: \.element.spelling) { index, term in
          HStack {
            Text(term.spelling)
            Spacer()
            Button("編集") {
              editingTermIndex = index
              termInput = term.spelling
            }
            Button("削除", role: .destructive) {
              Task {
                if await model.removeTerm(at: index) {
                  let wasEditing = editingTermIndex == index
                  editingTermIndex = Self.index(editingTermIndex, afterRemoving: index)
                  if wasEditing { resetTermInput() }
                }
              }
            }
          }
        }
        HStack {
          TextField("辞書語", text: $termInput)
          Button(editingTermIndex == nil ? "追加" : "更新", action: submitTerm)
          if editingTermIndex != nil {
            Button("取消", action: resetTermInput)
          }
        }
      }

      Section("置換ルール（読み・誤変換 → 表記）") {
        ForEach(Array(editor.rules.enumerated()), id: \.element.pattern) { index, rule in
          HStack {
            Text(rule.pattern)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Text(rule.replacement)
            if rule.ignoresCase {
              Text("大文字小文字を区別しない").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("編集") {
              editingRuleIndex = index
              patternInput = rule.pattern
              replacementInput = rule.replacement
              ignoresCaseInput = rule.ignoresCase
            }
            Button("削除", role: .destructive) {
              Task {
                if await model.removeRule(at: index) {
                  let wasEditing = editingRuleIndex == index
                  editingRuleIndex = Self.index(editingRuleIndex, afterRemoving: index)
                  if wasEditing { resetRuleInput() }
                }
              }
            }
          }
        }
        TextField("置換前（読み・誤変換）", text: $patternInput)
        TextField("置換後（表記）", text: $replacementInput)
        Toggle("大文字小文字を区別しない", isOn: $ignoresCaseInput)
        HStack {
          Button(editingRuleIndex == nil ? "追加" : "更新", action: submitRule)
          if editingRuleIndex != nil {
            Button("取消", action: resetRuleInput)
          }
        }
      }
    }
    .formStyle(.grouped)
    .disabled(model.isBusy)
  }

  /// 行を削除した後の、編集中の行の位置。編集中の行を削除したら nil
  private static func index(_ editing: Int?, afterRemoving removed: Int) -> Int? {
    guard let editing, editing != removed else { return nil }
    return editing > removed ? editing - 1 : editing
  }

  private func submitTerm() {
    Task {
      let saved =
        if let index = editingTermIndex {
          await model.updateTerm(at: index, to: termInput)
        } else {
          await model.addTerm(termInput)
        }
      if saved { resetTermInput() }
    }
  }

  private func submitRule() {
    Task {
      let saved =
        if let index = editingRuleIndex {
          await model.updateRule(
            at: index, pattern: patternInput, replacement: replacementInput,
            ignoresCase: ignoresCaseInput)
        } else {
          await model.addRule(
            pattern: patternInput, replacement: replacementInput, ignoresCase: ignoresCaseInput)
        }
      if saved { resetRuleInput() }
    }
  }

  private func resetTermInput() {
    termInput = ""
    editingTermIndex = nil
  }

  private func resetRuleInput() {
    patternInput = ""
    replacementInput = ""
    ignoresCaseInput = false
    editingRuleIndex = nil
  }
}
