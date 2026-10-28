import SwiftUI
import UtterAI

/// 設定画面の「整形の実行先と費用」タブの Sign in with ChatGPT の項目（AI-01, AC-05, #50）。
///
/// UI/UX ガイドライン（S11）に沿って、サインインのボタンは「Continue with ChatGPT」、プラン利用中は
/// 「Using ChatGPT plan」と「Manage usage」（ChatGPT の利用状況の設定）を出す。初回のサインイン後だけ
/// 「You're using your ChatGPT plan」の説明を出す。利用上限では「Manage usage」を主な操作にする。
/// OpenAI API キー方式は別の選択肢で、ここから自動で切り替えない（S7）。
struct ChatGPTAccountSection: View {
  let account: ChatGPTAccountSettingsModel
  /// 保存前の整形用モデル名（`SettingsForm.chatGPTRefinementModel`）
  @Binding var modelName: String

  var body: some View {
    Section {
      statusRows
      actionRow
      modelRows
      if let feedbackText {
        Text(feedbackText).font(.caption).foregroundStyle(.secondary)
      }
    } header: {
      Text("ChatGPT（Sign in with ChatGPT）")
    } footer: {
      Text(Self.footer).font(.caption).foregroundStyle(.secondary)
    }
    .task { await account.refresh() }
    .alert(
      "You're using your ChatGPT plan",
      isPresented: Binding(
        get: { account.showsPlanWelcome },
        set: { isPresented in
          guard !isPresented else { return }
          Task { await account.dismissPlanWelcome() }
        })
    ) {
      // 閉じると isPresented が false になり、次からは出さない
      Button("Got it") {}
    } message: {
      Text("utter からの整形は、あなたの ChatGPT プランの利用枠で処理されます。利用状況は ChatGPT の設定（Manage usage）で管理できます。")
    }
  }

  static let footer = [
    "サインインはブラウザで行い、utter は ChatGPT のパスワードを扱いません。",
    "トークンはこの Mac の Keychain にだけ保存し、iCloud で同期しません。",
    "送るのは整形する本文・スタイル区分・辞書語だけで、送信にはクラウド送信の同意が要ります。",
    "失敗したときは Local Basic で整形し、Claude や OpenAI API キー方式へは切り替えません。",
  ].joined()

  @ViewBuilder
  private var statusRows: some View {
    switch account.status {
    case nil:
      LabeledContent("状態") { Text("確認中…").foregroundStyle(.secondary) }
    case .unavailable:
      LabeledContent("状態") {
        Text("Keychain を読めません（Mac のロックを解除するか、署名されたビルドで実行してください）")
          .foregroundStyle(.secondary)
      }
    case .signedOut:
      LabeledContent("状態") { Text("サインインしていません").foregroundStyle(.secondary) }
    case .signedIn(let email, let planUsage):
      LabeledContent("アカウント") { Text(email ?? "ChatGPT アカウント") }
      planUsageRows(planUsage)
    }
  }

  @ViewBuilder
  private func planUsageRows(_ planUsage: ChatGPTAccountSession.PlanUsage) -> some View {
    switch planUsage {
    case .enabled:
      HStack {
        Label("Using ChatGPT plan", systemImage: "checkmark.circle")
        Spacer()
        Link("Manage usage", destination: ChatGPTSignIn.manageUsageURL)
      }
    case .notGranted:
      Text("ChatGPT プランの利用が許可されていないため、ChatGPT へは送りません。")
        .font(.callout)
      Button("ChatGPT プランの利用を有効にする") { account.signIn(requestsConsent: true) }
        .disabled(account.activity != .idle)
      Text("ChatGPT プランを使わない場合は、Local Basic・Claude・ChatGPT（OpenAI API キー方式）から選んでください。")
        .font(.caption).foregroundStyle(.secondary)
    case .pausedForUsageLimit:
      Text("Usage limit reached. ChatGPT プランまたは utter の利用上限に達したため、ChatGPT への送信を止めています。")
        .font(.callout)
      HStack {
        Link("Manage usage", destination: ChatGPTSignIn.manageUsageURL)
          .buttonStyle(.borderedProminent)
        Button("送信を再開") { Task { await account.resumePlanUsage() } }
      }
    case .notEligible:
      Text("このアカウント・ワークスペースでは ChatGPT プランを使えません。サインインし直すまで送りません。")
        .font(.callout)
    }
  }

  @ViewBuilder
  private var actionRow: some View {
    HStack {
      switch account.activity {
      case .signingIn:
        ProgressView().controlSize(.small)
        Text("ブラウザでサインインを続けてください…").foregroundStyle(.secondary)
        Spacer()
        Button("キャンセル") { account.cancelSignIn() }
      case .signingOut:
        ProgressView().controlSize(.small)
        Spacer()
      case .idle, .loadingModels:
        Spacer()
        if case .signedIn = account.status {
          Button("サインアウト") { Task { await account.signOut() } }
            .disabled(account.activity != .idle)
        } else {
          Button("Continue with ChatGPT") { account.signIn() }
            .buttonStyle(.borderedProminent)
            .disabled(account.status == .unavailable || account.activity != .idle)
        }
      }
    }
  }

  @ViewBuilder
  private var modelRows: some View {
    if case .signedIn(_, .enabled) = account.status {
      Picker("整形用モデル", selection: $modelName) {
        Text("選んでいません").tag("")
        ForEach(modelChoices, id: \.slug) { model in
          Text(model.displayName).tag(model.slug)
        }
      }
      HStack {
        Text("サインインしたアカウントで使えるモデルから選びます。")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if account.activity == .loadingModels {
          ProgressView().controlSize(.small)
        }
        Button("モデルの一覧を読み込む") { Task { await account.loadModels() } }
          .disabled(account.activity != .idle)
      }
    }
  }

  /// 読み込んだ一覧に、保存済みのモデル名がなければ足す（選んだ値を消さない）
  private var modelChoices: [ChatGPTModel] {
    var choices = account.models
    if !modelName.isEmpty, !choices.contains(where: { $0.slug == modelName }) {
      choices.insert(ChatGPTModel(slug: modelName, displayName: modelName), at: 0)
    }
    return choices
  }

  private var feedbackText: String? {
    switch account.feedback {
    case .signInFailed(let error): "サインインできませんでした（\(Self.describe(error))）。"
    case .signedOut: "サインアウトしました。"
    case .signedOutWithoutRevocation:
      "この Mac からはサインアウトしましたが、OpenAI 側での失効を確かめられませんでした。ChatGPT の設定から utter の接続を外せます。"
    case .modelsFailed(let error): "モデルの一覧を読み込めませんでした（\(Self.describe(error))）。"
    case nil: nil
    }
  }

  private static func describe(_ error: ChatGPTSignInError) -> String {
    switch error {
    case .accessDenied: "ChatGPT での許可が取り消されました"
    case .timedOut: "時間内にブラウザでの操作が終わりませんでした"
    case .listenerUnavailable: "この Mac でサインインの結果を受け取れません"
    case .browserUnavailable: "ブラウザを開けません"
    case .stateMismatch, .invalidCallback, .clientIDMismatch, .registrationIncomplete:
      "サインインの結果を確かめられません。もう一度お試しください"
    case .accountMismatch: "以前と別のアカウントでサインインしました"
    case .invalidIDToken: "アカウントの情報を確かめられません"
    case .storageFailed: "Keychain に保存できません"
    case .networkUnavailable: "OpenAI に接続できません"
    case .cancelled, .alreadyInProgress, .authorizationFailed, .invalidGrant,
      .refreshTokenUnusable, .invalidClient, .rejected, .invalidResponse:
      "もう一度お試しください"
    }
  }

  private static func describe(_ error: AIProviderError) -> String {
    switch error {
    case .authenticationExpired: "サインインし直してください"
    case .quotaExceeded: "ChatGPT プランを使えません"
    case .networkUnavailable: "OpenAI に接続できません"
    case .timeout: "時間内に応答がありませんでした"
    case .budgetExceeded, .invalidResponse, .cancelled: "もう一度お試しください"
    }
  }
}
