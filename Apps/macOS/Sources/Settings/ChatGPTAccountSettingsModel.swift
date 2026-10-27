import Foundation
import Observation
import UtterAI

/// 設定画面の「ChatGPT（Sign in with ChatGPT）」の状態と操作（AI-01, AC-05, #50, S11）。
///
/// サインイン・サインアウト・プラン利用の再開・モデル一覧の取得は `ChatGPTAccountSession` に任せ、ここは結果を画面へ渡すだけにする。
/// トークン・クライアントID は持たない。メールアドレスは、どのアカウントかを示すためにだけ表示する。
/// サインインは利用者の「Continue with ChatGPT」の操作でだけ始め、起動時や送信時に自動では始めない。
@MainActor
@Observable
final class ChatGPTAccountSettingsModel {
  /// 進行中の操作
  enum Activity: Hashable, Sendable {
    case idle
    case signingIn
    case signingOut
    case loadingModels
  }

  /// 直前の操作の結果。画面の文言は View が決める
  enum Feedback: Hashable, Sendable {
    case signInFailed(ChatGPTSignInError)
    case signedOut
    /// この Mac のトークンは消したが、失効を確かめられなかった（S6）
    case signedOutWithoutRevocation
    case modelsFailed(AIProviderError)
  }

  /// モデルの一覧を読む口。本番は `ChatGPTModelCatalog`、テストは決めた結果を返す
  typealias ListModels = @Sendable () async -> Result<[ChatGPTModel], AIProviderError>

  private(set) var status: ChatGPTAccountSession.Status?
  private(set) var activity = Activity.idle
  private(set) var feedback: Feedback?
  /// サインインしたアカウントで使えるモデル（S4）。読み込むまでは空
  private(set) var models: [ChatGPTModel] = []
  /// 初回のサインイン後の説明（「You're using your ChatGPT plan」, S11）を出すか
  var showsPlanWelcome = false

  private let session: ChatGPTAccountSession
  private let server: any ChatGPTLoopbackServer
  private let browser: any ChatGPTBrowserOpening
  private let listModels: ListModels
  private var signInTask: Task<Void, Never>?

  init(
    session: ChatGPTAccountSession, server: any ChatGPTLoopbackServer,
    browser: any ChatGPTBrowserOpening, listModels: ListModels? = nil
  ) {
    self.session = session
    self.server = server
    self.browser = browser
    if let listModels {
      self.listModels = listModels
    } else {
      self.listModels = { [session] in
        do throws(AIProviderError) {
          return .success(try await ChatGPTModelCatalog(account: session).models())
        } catch {
          return .failure(error)
        }
      }
    }
  }

  /// 保存済みの状態を読み直す（ネットワークを使わない）
  func refresh() async {
    status = await session.status()
    showsPlanWelcome = await session.needsPlanWelcome()
  }

  /// サインインを始める（「Continue with ChatGPT」）。ブラウザでの操作が終わるか、キャンセルするまで待つ。
  ///
  /// - Parameter requestsConsent: プラン利用を断ったあとに、利用者が明示的に有効にし直すとき `true`（S7）
  func signIn(requestsConsent: Bool = false) {
    guard activity == .idle else { return }
    activity = .signingIn
    feedback = nil
    let session = session
    let server = server
    let browser = browser
    signInTask = Task { @MainActor in
      let result: Result<ChatGPTAccountSession.Status, ChatGPTSignInError>
      do throws(ChatGPTSignInError) {
        result = .success(
          try await session.signIn(
            server: server, browser: browser, requestsConsent: requestsConsent))
      } catch {
        result = .failure(error)
      }
      await self.finishSignIn(result)
    }
  }

  /// 進行中のサインインをやめる（待ち受けを閉じる）
  func cancelSignIn() {
    signInTask?.cancel()
  }

  /// 進行中のサインインが終わるまで待つ（テスト用）
  func waitForSignIn() async {
    await signInTask?.value
  }

  private func finishSignIn(
    _ result: Result<ChatGPTAccountSession.Status, ChatGPTSignInError>
  ) async {
    signInTask = nil
    activity = .idle
    switch result {
    case .success(let status):
      self.status = status
      models = []
      showsPlanWelcome = await session.needsPlanWelcome()
    case .failure(let error):
      // 画面を閉じた・キャンセルしたときは失敗として出さない
      if error != .cancelled {
        feedback = .signInFailed(error)
      }
      status = await session.status()
    }
  }

  /// サインアウトする（S6）。失効を試してから、この Mac のトークンを消す
  func signOut() async {
    guard activity == .idle else { return }
    activity = .signingOut
    let result = await session.signOut()
    feedback = result == .revoked ? .signedOut : .signedOutWithoutRevocation
    models = []
    status = await session.status()
    activity = .idle
  }

  /// 利用上限で止めたプラン利用を再開する（S7）
  func resumePlanUsage() async {
    await session.resumePlanUsage()
    status = await session.status()
  }

  /// 初回のサインイン後の説明を閉じる。次からは出さない（S11）
  func dismissPlanWelcome() async {
    showsPlanWelcome = false
    await session.markPlanWelcomeShown()
  }

  /// サインインしたアカウントのモデルの一覧を読む（S4）
  func loadModels() async {
    guard activity == .idle else { return }
    activity = .loadingModels
    feedback = nil
    switch await listModels() {
    case .success(let loaded):
      models = loaded
    case .failure(let error):
      models = []
      feedback = .modelsFailed(error)
    }
    status = await session.status()
    activity = .idle
  }
}
