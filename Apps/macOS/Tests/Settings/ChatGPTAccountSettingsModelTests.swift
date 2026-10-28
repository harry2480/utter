import Foundation
import Testing
import UtterAI

/// 設定画面の Sign in with ChatGPT の状態と操作（AC-05, #50）。ブラウザ・ループバック・認証サーバーは Stub に置き換える。
@MainActor
struct ChatGPTAccountSettingsModelTests {
  private func model(
    store: StubChatGPTAccountStore = StubChatGPTAccountStore(),
    authClient: StubChatGPTAuthClient = StubChatGPTAuthClient(),
    flow: StubChatGPTSignInFlow = StubChatGPTSignInFlow { _ in nil },
    listModels: ChatGPTAccountSettingsModel.ListModels? = nil
  ) -> ChatGPTAccountSettingsModel {
    ChatGPTAccountSettingsModel(
      session: ChatGPTAccountSession(store: store, authClient: authClient),
      server: flow, browser: flow, listModels: listModels ?? { .success([]) })
  }

  @Test("#50: 保存済みの状態を読み、サインインは利用者の操作まで始めない")
  func refreshDoesNotStartSignIn() async {
    let flow = StubChatGPTSignInFlow { _ in nil }
    let model = model(store: .signedIn(), flow: flow)
    await model.refresh()
    #expect(model.status == .signedIn(email: "user@example.com", planUsage: .enabled))
    #expect(flow.openedURLs.isEmpty)
    #expect(flow.startCount == 0)
    // 初回のサインイン後の説明（S11）はまだ出していない
    #expect(model.showsPlanWelcome)
  }

  @Test("S3: state が一致しないコールバックはサインインの失敗として知らせ、サインインしない")
  func signInFailureIsReported() async {
    let flow = StubChatGPTSignInFlow { StubChatGPTSignInFlow.callback(for: $0, state: "forged") }
    let model = model(flow: flow)
    model.signIn()
    #expect(model.activity == .signingIn)
    await model.waitForSignIn()
    #expect(model.activity == .idle)
    #expect(model.feedback == .signInFailed(.stateMismatch))
    #expect(model.status == .signedOut(hasRegistration: false))
    #expect(flow.openedURLs.count == 1)
  }

  @Test("#50: サインインをキャンセルしたら失敗として出さず、待ち受けを閉じる")
  func cancelSignIn() async {
    let flow = StubChatGPTSignInFlow { _ in nil }
    let model = model(flow: flow)
    model.signIn()
    while flow.openedURLs.isEmpty {
      await Task.yield()
    }
    model.cancelSignIn()
    await model.waitForSignIn()
    #expect(model.activity == .idle)
    #expect(model.feedback == nil)
    #expect(flow.stopCount == 1)
  }

  @Test("S6: サインアウトすると失効を試し、確かめられなければそう知らせる")
  func signOut() async {
    let authClient = StubChatGPTAuthClient(revokeError: .networkUnavailable)
    let model = model(store: .signedIn(), authClient: authClient)
    await model.refresh()
    await model.signOut()
    #expect(model.feedback == .signedOutWithoutRevocation)
    #expect(model.status == .signedOut(hasRegistration: true))
    #expect(await authClient.revokedTokens == ["stub-refresh-token"])
  }

  @Test("S4: モデルの一覧を読み、読めなければ理由を知らせる")
  func loadModels() async {
    let models = [ChatGPTModel(slug: "model-a", displayName: "Model A")]
    let loaded = model(store: .signedIn(), listModels: { .success(models) })
    await loaded.loadModels()
    #expect(loaded.models == models)
    #expect(loaded.feedback == nil)

    let failed = model(store: .signedIn(), listModels: { .failure(.networkUnavailable) })
    await failed.loadModels()
    #expect(failed.models.isEmpty)
    #expect(failed.feedback == .modelsFailed(.networkUnavailable))
  }

  @Test("S11: 初回のサインイン後の説明は閉じたら次から出さない")
  func planWelcomeIsShownOnce() async {
    let store = StubChatGPTAccountStore.signedIn()
    let first = model(store: store)
    await first.refresh()
    #expect(first.showsPlanWelcome)
    await first.dismissPlanWelcome()
    #expect(!first.showsPlanWelcome)

    let next = model(store: store)
    await next.refresh()
    #expect(!next.showsPlanWelcome)
  }
}
