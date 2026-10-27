import Security
import SwiftUI
import UtterAI

/// API キーの設定画面（設定画面の「API キー」タブ, AC-12）。Claude（整形・Edit Mode）と OpenAI（クラウド STT, #188）の
/// キーを別の項目で持つ。状態と操作はキーごとの `APIKeySettingsModel` が持つ。
///
/// - 入力欄は `SecureField`（伏せ字。コピー・切り取り・ドラッグで取り出せない）
/// - 保存済みのキーは再表示しない。値に依存しない伏せ字で保存済みであることだけを示す
/// - パスワードの自動入力・保存の候補に出さないよう `textContentType` を指定しない
///   （パスワード管理に保存されると iCloud で同期されうるため）
/// - 画面を閉じたら入力を消す
struct APIKeySettingsView: View {
  /// Claude API キー（整形・Edit Mode）
  let claude: APIKeySettingsModel
  /// OpenAI API キー（クラウド STT, #188）
  let openAI: APIKeySettingsModel

  var body: some View {
    Form {
      APIKeySection(model: claude, labels: .claude)
      APIKeySection(model: openAI, labels: .openAI)
    }
    .formStyle(.grouped)
    .onAppear {
      claude.refresh()
      openAI.refresh()
    }
    .onDisappear {
      claude.clearInput()
      openAI.clearInput()
    }
  }
}

/// キーごとの見出し・入力例・削除の説明
private struct APIKeyLabels {
  let title: String
  let placeholder: String
  let deletionMessage: String

  static let claude = APIKeyLabels(
    title: "Claude API キー", placeholder: "sk-ant-…",
    deletionMessage: "削除すると Claude による整形と Edit Mode は使えなくなります。")
  static let openAI = APIKeyLabels(
    title: "OpenAI API キー（クラウド音声認識）", placeholder: "sk-…",
    deletionMessage: "削除するとクラウド音声認識は使えなくなります。")
}

/// 1つのキーの状態・入力・保存・削除
private struct APIKeySection: View {
  @Bindable var model: APIKeySettingsModel
  let labels: APIKeyLabels
  @State private var isConfirmingDeletion = false

  var body: some View {
    Section {
      LabeledContent("状態") {
        Text(statusText)
          .foregroundStyle(model.status == .saved ? .primary : .secondary)
      }
      SecureField("API キー", text: $model.input, prompt: Text(labels.placeholder))
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
          .disabled(!model.canSave)
      }
    } header: {
      Text(labels.title)
    } footer: {
      Text("キーはこの Mac の Keychain にだけ保存し、iCloud で同期しません。保存したキーは表示しません。")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .confirmationDialog(
      "\(labels.title)を削除しますか？", isPresented: $isConfirmingDeletion
    ) {
      Button("削除", role: .destructive) { model.delete() }
    } message: {
      Text(labels.deletionMessage)
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
