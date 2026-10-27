import Foundation
import UtterAI
import UtterCore
import UtterPersistence
import UtterText

/// Edit Mode の選択テキストと音声指示の送信（AC-14, AC-06, AC-12, AI-04, AI-05, CTX-03）。
///
/// 送るたびに保存済みの最新の設定を読み、次がすべてそろったときだけ、`EditRouter` 経由で Claude へ1回だけ送る。
/// どれかが欠ければ送らず、理由を返す（ローカルでは音声指示による編集ができないため、代わりの結果は作らない）。
/// 1. Claude への選択テキストの送信（`editSelection`）に同意している（AC-06。整形の送信への同意とは別。
///    同意の画面が保存した最新の値を、送る直前にも読み直す）
/// 2. Claude API キーが保存されていて読み出せる（AC-12。整形と同じ保存先。値はここでは使わず、送信時にプロバイダーが読み出す）
/// 3. 入力先が機密入力でない（7章, AC-12。判定できなければ送らない）
/// 4. 予算上限を確かめられる（AI-04, AI-05。整形と同じ月次予算・単価表・今月の累計から `BudgetGuard` を作る）
///
/// 整形の処理系（Local Basic / クラウド AI）の選択は見ない（Edit Mode は送信が前提で、同意を別に求めるため）。
/// モデル名は整形用モデル名（AI-07）を使う。推定費用は整形と同じ累計に記録する。
/// 送るのは選択テキスト・音声指示・辞書語だけで、bundle ID・URL・ウィンドウタイトル・選択範囲の外の本文は送らない（CTX-03）。
/// 推定費用の累計を保存できなかった（`BudgetGuard.hasPersistenceFailure`）後は、アプリを起動し直すまで送らない（安全側）。
/// 選択テキスト・音声指示・編集案・API キーはログに出さない。
@MainActor
final class EditModeRequestPipeline: EditRequestSending {
  /// 送信先のプロバイダーを作る。本番は `ClaudeProvider(apiKeyStore:configuration:)`、テストは Stub の送信部を使う
  typealias MakeProvider =
    @Sendable (ClaudeProvider.Configuration, any APIKeyStore) -> any AIEditProvider

  private let settingsStore: AppSettingsStore
  private let apiKeyStore: any APIKeyStore
  private let database: @MainActor () async throws -> UtterDatabase
  private let makeProvider: MakeProvider
  private let timeout: Duration
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  /// 推定費用の累計を保存できなかったか。一度でも失敗したら、以降は送らない
  private var hasUsagePersistenceFailure = false

  /// - Parameters:
  ///   - settingsStore: モデル名・予算・同意の保存先。設定画面・同意の画面と同じものを渡す
  ///   - apiKeyStore: Claude API キーの保存先。API キーの画面と同じものを渡す
  ///   - database: 辞書と推定費用の累計を保存するデータベース（整形と同じもの）
  ///   - timeout: 応答待ちの上限時間
  ///   - now: 実時刻（費用を計上する月の判定）
  ///   - calendar: 費用を計上する月の判定に使う暦
  init(
    settingsStore: AppSettingsStore,
    apiKeyStore: any APIKeyStore,
    database: @escaping @MainActor () async throws -> UtterDatabase,
    makeProvider: @escaping MakeProvider = { configuration, store in
      ClaudeProvider(apiKeyStore: store, configuration: configuration)
    },
    timeout: Duration = RefinementRouter.defaultTimeout,
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .current
  ) {
    self.settingsStore = settingsStore
    self.apiKeyStore = apiKeyStore
    self.database = database
    self.makeProvider = makeProvider
    self.timeout = timeout
    self.now = now
    self.calendar = calendar
  }

  /// ChatGPT への送信は #50 の判定待ちのため、Claude だけ
  var destination: CloudAIProviderKind { .claude }

  func currentConsent() -> ConsentState {
    ConsentSettingsController(store: settingsStore).currentConsent()
  }

  func dictionaryTerms() async -> [String] {
    guard let database = try? await database() else { return [] }
    return await Task.detached {
      guard let contents = try? DictionaryStore(database: database).contents(),
        let dictionary = try? DictionaryEditorModel.dictionary(from: contents)
      else { return [] }
      var seen: Set<String> = []
      return dictionary.terms.map(\.spelling).filter { seen.insert($0).inserted }
    }.value
  }

  func send(
    _ request: EditRequest,
    sensitivity: @escaping @MainActor () -> SensitiveInputDecision
  ) async throws(CancellationError) -> EditSendResult {
    func notEdited(_ reason: EditFailureReason) -> EditSendResult {
      .outcome(EditOutcome(content: .notEdited(reason)))
    }
    let settings = settingsStore.load()
    guard !hasUsagePersistenceFailure else { return .unavailable(.budgetUnavailable) }
    guard let configuration = try? ClaudeProvider.Configuration(model: settings.refinementModel)
    else { return .unavailable(.cloudUnavailable) }
    let provider = makeProvider(configuration, apiKeyStore)
    guard currentConsent().allows(.editSelection(provider.destination)) else {
      return notEdited(.consentNotGranted)
    }
    // キーがなければ予算の確認も送信もしない
    do throws(APIKeyStoreError) {
      guard try apiKeyStore.load() != nil else { return .unavailable(.apiKeyNotSet) }
    } catch {
      return .unavailable(.apiKeyUnavailable)
    }
    guard sensitivity().allowsCloudTransmission else { return notEdited(.sensitiveInputSuppressed) }
    guard let router = try? EditRouter(provider: provider, timeout: timeout) else {
      return .unavailable(.cloudUnavailable)
    }
    guard
      let budget = await makeBudget(
        settings: settings, configuration: configuration, request: request)
    else {
      if Task.isCancelled { throw CancellationError() }
      return .unavailable(.budgetUnavailable)
    }

    // 予算の確認を待つ間の撤回・入力先の変化も反映するよう、送る直前に最新の同意と入力先を読み直す。
    // `EditRouter` は同期的に同意と判定を求めるため、ここで読み直した値を渡す
    let consent = currentConsent()
    let decision = sensitivity()
    let outcome: EditOutcome
    do throws(CancellationError) {
      outcome = try await router.edit(
        request, consent: { consent }, budget: budget, sensitivity: { decision })
    } catch {
      // 送信後にキャンセルされても推定費用は記録されるため、保存の失敗は確かめる
      await noteUsagePersistence(of: budget.guard)
      throw error
    }
    await noteUsagePersistence(of: budget.guard)
    return .outcome(outcome)
  }

  /// 今月の予算判定に使う `BudgetGuard` を、保存済みの累計から作る（AI-04, AI-05。整形と同じ）。
  /// 予算・単価表が未設定、通貨が一致しない、累計を読めない場合は `nil`（送らない）
  private func makeBudget(
    settings: AppSettings, configuration: ClaudeProvider.Configuration, request: EditRequest
  ) async -> RefinementBudget? {
    guard
      let cost = try? CloudCostBridge.configuration(for: settings, at: now(), in: calendar),
      let database = try? await database()
    else { return nil }
    let usageStore = MonthlyUsageStore(database: database)
    guard
      let budgetGuard = try? await Task.detached(operation: {
        try CloudCostBridge.makeBudgetGuard(configuration: cost, usageStore: usageStore)
      }).value
    else { return nil }
    return RefinementBudget(
      guard: budgetGuard, model: configuration.model,
      expectedUsage: Self.expectedUsage(for: request, maxOutputTokens: configuration.maxTokens),
      month: cost.month)
  }

  private func noteUsagePersistence(of budgetGuard: BudgetGuard) async {
    if await budgetGuard.hasPersistenceFailure {
      hasUsagePersistenceFailure = true
    }
  }

  /// 送信前に予約する見込みの使用量。少なめに見積もらないよう、入力はプロンプトのバイト数（1トークン1バイト以上）に
  /// 余裕を足し、出力は上限（max_tokens）にする（整形と同じ見積もり方）
  static func expectedUsage(for request: EditRequest, maxOutputTokens: Int) -> TokenUsage {
    let prompt = EditPromptBuilder().build(request)
    let promptBytes = prompt.system.utf8.count + prompt.user.utf8.count
    return TokenUsage(inputTokens: promptBytes + 64, outputTokens: maxOutputTokens)
  }
}
