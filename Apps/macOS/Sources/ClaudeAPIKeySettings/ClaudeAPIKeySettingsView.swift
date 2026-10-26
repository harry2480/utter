import Security
import SwiftUI
import UtterAI

/// Claude API キーの設定画面（設定画面の「API キー」タブ, AC-12）。状態と操作は `APIKeySettingsModel` が持つ。
///
/// - 入力欄は `SecureField`（伏せ字。コピー・切り取り・ドラッグで取り出せない）
/// - 保存済みのキーは再表示しない。値に依存しない伏せ字で保存済みであることだけを示す
/// - パスワードの自動入力・保存の候補に出さないよう `textContentType` を指定しない
///   （パスワード管理に保存されると iCloud で同期されうるため）
/// - 画面を閉じたら入力を消す
struct ClaudeAPIKeySettingsView: View {
  @Bindable var model: APIKeySettingsModel
  @State private var isConfirmingDeletion = false

  var body: some View {
    Form {
      Section {
        LabeledContent("状態") {
          Text(statusText)
            .foregroundStyle(model.status == .saved ? .primary : .secondary)
        }
        SecureField("API キー", text: $model.input, prompt: Text("sk-ant-…"))
          .autocorrectionDisabled()
          .onSubmit(save)
        HStack {
          if let feedbackText {
            Text(feedbackText)
              .font(.callout)
              .foregroundStyle(isFailure ? .red : .secondary)
          }
          Spacer()
          Button("削除…", role: .destructive) { isConfirmingDeletion = true }
            .disabled(!model.canDelete)
          Button("保存", action: save)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
        }
      } header: {
        Text("Claude API キー")
      } footer: {
        Text("キーはこの Mac の Keychain にだけ保存し、iCloud で同期しません。保存したキーは表示しません。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear { model.refresh() }
    .onDisappear { model.clearInput() }
    .confirmationDialog(
      "Claude API キーを削除しますか？", isPresented: $isConfirmingDeletion
    ) {
      Button("削除", role: .destructive) { model.delete() }
    } message: {
      Text("削除すると Claude による整形は使えなくなります。")
    }
  }

  private func save() {
    guard model.canSave else { return }
    model.save()
  }

  private var statusText: String {
    switch model.status {
    case .saved: "保存済み（••••••••）"
    case .notSaved: "未設定"
    case .unavailable(let error): "確認できません（\(Self.describe(error))）"
    case nil: "確認中…"
    }
  }

  private var feedbackText: String? {
    switch model.feedback {
    case .saved: "保存しました。"
    case .deleted: "削除しました。"
    case .invalidInput(.empty): "API キーを入力してください。"
    case .invalidInput(.invalidCharacters):
      "API キーに使えない文字（空白・改行・全角文字など）が含まれています。"
    case .saveFailed(let error): "保存できませんでした（\(Self.describe(error))）。"
    case .deleteFailed(let error): "削除できませんでした（\(Self.describe(error))）。"
    case nil: nil
    }
  }

  private var isFailure: Bool {
    switch model.feedback {
    case .invalidInput, .saveFailed, .deleteFailed: true
    case .saved, .deleted, nil: false
    }
  }

  /// エラーの表示。キーの値は含まない
  private static func describe(_ error: APIKeyStoreError) -> String {
    switch error {
    case .operationFailed(let code) where code == errSecMissingEntitlement:
      "署名されたビルドで実行してください。Keychain エラー \(code)"
    case .operationFailed(let code) where code == errSecInteractionNotAllowed:
      "Mac のロックを解除してください。Keychain エラー \(code)"
    case .operationFailed(let code):
      "Keychain エラー \(code)"
    case .invalidStoredData:
      "保存されている値を読めません。保存し直してください"
    }
  }
}
