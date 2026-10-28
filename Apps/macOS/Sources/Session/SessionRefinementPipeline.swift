import Foundation
import UtterAI
import UtterCore
import UtterPersistence
import UtterText

/// セッションの整形（TXT-01, TXT-03, AI-01, AI-03, AI-04, AC-06, AC-12, CTX-01〜03）。
///
/// 整形のたびに保存済みの最新の設定を読み、`RefinementRequestPreparer` で辞書の置換と辞書語・スタイル区分を添えた入力を作る。
/// 次がすべてそろったときだけ、`RefinementRouter` 経由で Claude へ1回だけ送る。どれかが欠ければ送らず、Local Basic で整形する。
/// 1. 整形モードが Raw でない（Raw は整形も置換もせず、辞書も読まない）
/// 2. 整形の処理系にクラウド AI を選んでいる（AI-03。既定は Local Basic）
/// 3. Claude への整形の送信に同意している（AC-06。同意の画面が保存した最新の値を、送る直前にも読み直す）
/// 4. Claude API キーが保存されていて読み出せる（AC-12。値はここでは使わず、送信時にプロバイダーが読み出す）
/// 5. 入力先が機密入力でない（7章, AC-12。判定できなければ送らない）
/// 6. 予算上限を確かめられる（AI-04, AI-05。月次予算・単価表・今月の累計から `BudgetGuard` を作れる）
///
/// クラウド整形の失敗・上限時間の超過・検証失敗・予算超過は、`RefinementRouter` がローカル整形の結果に退避する（4.1節）。
/// クラウドへ送るのは整形モード・スタイル区分・辞書語・本文だけで、bundle ID・URL・ホスト名・ウィンドウタイトルは送らない（CTX-03）。
/// スタイルは `ContextStyleResolver`（サイト別 → アプリ別 → 既定）で選ぶ（CTX-01, CTX-02）。サイト単位の識別が許可され、
/// サイト別の上書きがあるときだけ、前面のブラウザで表示中のページのホスト名を `FrontmostSiteHostReading` で読む。
/// ホスト名はスタイルの判定にだけ使い、保持・送信・記録しない。
/// 推定費用の累計を保存できなかった（`BudgetGuard.hasPersistenceFailure`）後は、累計が実際より少ない可能性があるため、
/// アプリを起動し直すまでクラウドへ送らない（安全側）。
/// 計測器（`PerfIntervalMeasuring`）を渡すと、送信先の `refine` を `LLMComplete` の区間として計測する（6章, #52）。
///
/// クラウド AI の送信先に Sign in with ChatGPT（#50）を選んだときは、Claude の代わりに次がそろったときだけ
/// `ChatGPTPlanProvider` へ1回だけ送る（1・5 は Claude と同じ）。予算は使わない（利用者の ChatGPT プランの利用枠, AI-05）。
/// - ChatGPT の整形用モデルを選んでいる（未選択なら送らない。モデル名をコードに固定しない）
/// - ChatGPT（OpenAI）への整形の送信に同意している（AC-06）
/// - サインインしていて、プラン利用が許可されている（S3, S7）
/// 失敗したら Local Basic へ退避し、OpenAI API キー方式へは切り替えない（AI-01, S7）。
///
/// クラウド AI の送信先に OpenAI API キー方式（#58）を選んだときは、Claude の代わりに次がそろったときだけ
/// `OpenAIProvider` へ1回だけ送る（1・5 は Claude と同じ）。トークン課金のため、予算は Claude と同じ月次予算・単価表・
/// 今月の累計で確かめる（AI-04, AI-05。`OpenAIProvider.isTokenBilled == true`）。
/// - OpenAI API キー方式の整形用モデル名を入力している（未入力なら送らない。モデル名をコードに固定しない）
/// - ChatGPT（OpenAI）への整形の送信に同意している（AC-06。Sign in with ChatGPT と同じ送信先として確かめる）
/// - OpenAI API キーが保存されていて読み出せる（クラウド STT と同じキー。Claude API キーとは別）
/// - 予算上限を確かめられる（上の 6 と同じ）
/// 失敗したら Local Basic へ退避し、Sign in with ChatGPT や Claude へは切り替えない（AI-01, S7）。
///
/// 失敗時に別のクラウドへ切り替える設定（`AppSettings.cloudRefinementFallbackEnabled`, AI-04。既定は無効）を選んだときだけ、
/// 選んだ送信先へ送って退避した（`cloudFallback`）後に、もう一方（Claude ↔ Sign in with ChatGPT）へ1回だけ送り直す。
/// 切り替え先へも上の条件（その送信先への送信の同意・API キーと予算、またはサインインとモデル名・入力先）を同じく確かめ、
/// そろわなければ送らない（AC-06）。同意・キー・サインインがなくて最初の送信先へ送らなかったとき（`localOnly`）は切り替えない。
/// 切り替え先の応答が検証を通ったときだけ使い、それ以外は最初の送信先の退避の結果（理由）を返す。
/// OpenAI API キー方式は切り替え先にせず、OpenAI API キー方式を選んだときは切り替えない（`alternative`）。
@MainActor
final class SessionRefinementPipeline: SessionRefining {
  /// 送信先のプロバイダーを作る。本番は `ClaudeProvider(apiKeyStore:configuration:)`、テストは Stub の送信部を使う
  typealias MakeProvider =
    @Sendable (ClaudeProvider.Configuration, any APIKeyStore) -> any AIProvider
  /// Sign in with ChatGPT の送信先を作る。本番は `ChatGPTPlanProvider`、テストは Stub の送信部を使う
  typealias MakeChatGPTProvider =
    @Sendable (ChatGPTPlanProvider.Configuration, ChatGPTAccountSession) -> any AIProvider
  /// OpenAI API キー方式の送信先を作る。本番は `OpenAIProvider`、テストは Stub の送信部を使う。
  /// API キーは作った送信先だけが持ち、ここでは保持しない
  typealias MakeOpenAIProvider =
    @Sendable (OpenAIProvider.Configuration, APIKey) -> any AIProvider

  private let settingsStore: AppSettingsStore
  private let apiKeyStore: any APIKeyStore
  private let database: @MainActor () async throws -> UtterDatabase
  private let makeProvider: MakeProvider
  private let chatGPTAccount: ChatGPTAccountSession?
  private let makeChatGPTProvider: MakeChatGPTProvider
  private let openAIAPIKeyStore: (any APIKeyStore)?
  private let makeOpenAIProvider: MakeOpenAIProvider
  private let localRefiner: any LocalRefiner
  private let siteHostReader: any FrontmostSiteHostReading
  private let timeout: Duration
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  private let measurer: (any PerfIntervalMeasuring)?
  /// 推定費用の累計を保存できなかったか。一度でも失敗したら、以降はクラウドへ送らない
  private var hasUsagePersistenceFailure = false

  /// - Parameters:
  ///   - settingsStore: 処理系・整形モード・モデル名・予算・同意の保存先。設定画面・同意の画面と同じものを渡す
  ///   - apiKeyStore: Claude API キーの保存先。API キーの画面と同じものを渡す
  ///   - database: 辞書と推定費用の累計を保存するデータベース
  ///   - chatGPTAccount: Sign in with ChatGPT のアカウント（#50）。設定画面と同じものを渡す。`nil` なら ChatGPT へは送らない
  ///   - openAIAPIKeyStore: OpenAI API キーの保存先（#58）。クラウド STT・API キーの画面と同じものを渡す。
  ///     `nil` なら OpenAI API キー方式では送らない
  ///   - siteHostReader: 前面のブラウザで表示中のホスト名を読む口（CTX-02）。サイト単位の識別が許可されたときだけ呼ぶ
  ///   - timeout: クラウド整形の応答待ちの上限時間（4.1節）
  ///   - now: 実時刻（費用を計上する月の判定）
  ///   - calendar: 費用を計上する月の判定に使う暦。設定画面の推定費用の表示と同じものを使う
  ///   - measurer: 性能計測の区間の記録（#52）。`nil` なら計測しない
  init(
    settingsStore: AppSettingsStore,
    apiKeyStore: any APIKeyStore,
    database: @escaping @MainActor () async throws -> UtterDatabase,
    makeProvider: @escaping MakeProvider = { configuration, store in
      ClaudeProvider(apiKeyStore: store, configuration: configuration)
    },
    chatGPTAccount: ChatGPTAccountSession? = nil,
    makeChatGPTProvider: @escaping MakeChatGPTProvider = { configuration, account in
      ChatGPTPlanProvider(account: account, configuration: configuration)
    },
    openAIAPIKeyStore: (any APIKeyStore)? = nil,
    makeOpenAIProvider: @escaping MakeOpenAIProvider = { configuration, apiKey in
      OpenAIProvider(apiKey: apiKey.value, configuration: configuration)
    },
    localRefiner: any LocalRefiner = LocalBasicRefiner(),
    siteHostReader: any FrontmostSiteHostReading = AccessibilitySiteHostReader(),
    timeout: Duration = RefinementRouter.defaultTimeout,
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .current,
    measurer: (any PerfIntervalMeasuring)? = nil
  ) {
    self.settingsStore = settingsStore
    self.apiKeyStore = apiKeyStore
    self.database = database
    self.makeProvider = makeProvider
    self.chatGPTAccount = chatGPTAccount
    self.makeChatGPTProvider = makeChatGPTProvider
    self.openAIAPIKeyStore = openAIAPIKeyStore
    self.makeOpenAIProvider = makeOpenAIProvider
    self.localRefiner = localRefiner
    self.siteHostReader = siteHostReader
    self.timeout = timeout
    self.now = now
    self.calendar = calendar
    self.measurer = measurer
  }

  var selectsCloudRefinement: Bool {
    let settings = settingsStore.load()
    return settings.refinementEngine == .cloudAI && RefinementMode(settings.refinementMode) != .raw
  }

  func refinementSummary(frontmostApp: String?) -> HUDRefinementSummary {
    let settings = settingsStore.load()
    let mode = HUDRefinementMode(settings.refinementMode)
    let style = settings.contextStyleResolver.app.style(forBundleID: frontmostApp)
    return HUDRefinementSummary(mode: mode, style: style)
  }

  func refine(
    _ transcript: String,
    frontmostApp: String?,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext,
    willSend: @escaping @MainActor @Sendable (CloudAIProviderKind) -> Void
  ) async throws(CancellationError) -> SessionRefinementResult {
    let settings = settingsStore.load()
    let mode = RefinementMode(settings.refinementMode)
    // Raw は整形も置換もしないため、辞書を読まず、送らない。スタイルを使わないため、ホスト名も読まない
    guard mode != .raw else {
      return SessionRefinementResult(text: transcript, route: .localOnly(.rawMode))
    }
    let styleResolver = settings.contextStyleResolver
    // 録音が終わった直後の表示中のページで判定する。ホスト名はこの判定の後に保持しない
    let siteHost = Self.siteHost(
      reader: siteHostReader, resolver: styleResolver.site, frontmostApp: frontmostApp)
    let style = styleResolver.style(forBundleID: frontmostApp, siteHost: siteHost)
    let dictionary = await loadDictionary()
    if Task.isCancelled { throw CancellationError() }
    let request: RefinementRequest
    if let dictionary {
      // 置換と辞書語は `RefinementRequestPreparer` で作り、スタイルはサイト別を含めて選んだ値に差し替える
      let preparer = RefinementRequestPreparer(
        dictionary: dictionary, styleResolver: styleResolver.app)
      let prepared = preparer.prepare(
        transcript: transcript, mode: mode, frontmostBundleID: frontmostApp)
      request = RefinementRequest(
        text: prepared.text, mode: prepared.mode, style: style,
        dictionaryTerms: prepared.dictionaryTerms)
    } else {
      // 辞書を読めなければ、置換・辞書語なしで整形を続ける（発話を失わない）
      request = RefinementRequest(text: transcript, mode: mode, style: style)
    }

    func local(_ reason: SessionRefinementRoute.LocalReason) -> SessionRefinementResult {
      SessionRefinementResult(text: localRefiner.refine(request), route: .localOnly(reason))
    }
    guard settings.refinementEngine == .cloudAI else { return local(.localEngineSelected) }
    let selected = settings.cloudRefinementProvider
    let first = try await refineInCloud(
      request, with: selected, selected: selected, settings: settings, sensitivity: sensitivity,
      willSend: willSend)
    // 送ろうとして退避したときだけ、設定で選んでいればもう一方へ切り替える（AI-04。既定は切り替えない）
    guard case .cloudFallback = first.route, settings.cloudRefinementFallbackEnabled,
      let alternative = selected.alternative
    else {
      return first
    }
    let switched = try await refineInCloud(
      request, with: alternative, selected: selected, settings: settings,
      sensitivity: sensitivity, willSend: willSend)
    return switched.route == .cloud ? switched : first
  }

  /// `provider` へ送る。`selected` は設定で選んだ送信先で、`provider` と違えば失敗時の切り替え先として送る。
  /// `willSend` は、その送信先へ実際に送る直前（同意・入力先・予算の確認と予約の後）にだけ呼ばれ、送らなければ呼ばれない
  private func refineInCloud(
    _ request: RefinementRequest, with provider: CloudRefinementProvider,
    selected: CloudRefinementProvider, settings: AppSettings,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext,
    willSend: @escaping @MainActor @Sendable (CloudAIProviderKind) -> Void
  ) async throws(CancellationError) -> SessionRefinementResult {
    switch provider {
    case .claude:
      return try await refineWithClaude(
        request, selected: selected, settings: settings, sensitivity: sensitivity,
        willSend: willSend)
    case .chatGPTSignIn:
      return try await refineWithChatGPT(
        request, selected: selected, settings: settings, sensitivity: sensitivity,
        willSend: willSend)
    case .openAIAPIKey:
      return try await refineWithOpenAI(
        request, selected: selected, settings: settings, sensitivity: sensitivity,
        willSend: willSend)
    }
  }

  /// Claude へ送る。予算の上限を確かめてから送る（AI-04, AI-05）
  private func refineWithClaude(
    _ request: RefinementRequest, selected: CloudRefinementProvider, settings: AppSettings,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext,
    willSend: @escaping @MainActor @Sendable (CloudAIProviderKind) -> Void
  ) async throws(CancellationError) -> SessionRefinementResult {
    func local(_ reason: SessionRefinementRoute.LocalReason) -> SessionRefinementResult {
      SessionRefinementResult(text: localRefiner.refine(request), route: .localOnly(reason))
    }
    guard !hasUsagePersistenceFailure else { return local(.budgetUnavailable) }
    guard let configuration = try? ClaudeProvider.Configuration(model: settings.refinementModel)
    else { return local(.cloudUnavailable) }
    let provider = measured(makeProvider(configuration, apiKeyStore))
    guard currentConsent().allows(.textRefinement(provider.destination)) else {
      return local(.consentNotGranted)
    }
    // キーがなければ予算の確認も送信もしない
    do throws(APIKeyStoreError) {
      guard try apiKeyStore.load() != nil else { return local(.apiKeyNotSet) }
    } catch {
      return local(.apiKeyUnavailable)
    }
    guard Self.decide(sensitivity(), settings: settings).allowsCloudTransmission else {
      return local(.sensitiveInput)
    }
    guard
      let router = try? RefinementRouter(
        provider: provider, localRefiner: localRefiner, timeout: timeout)
    else { return local(.cloudUnavailable) }
    guard
      let budget = await makeBudget(
        settings: settings, model: configuration.model, maxOutputTokens: configuration.maxTokens,
        request: request)
    else {
      if Task.isCancelled { throw CancellationError() }
      return local(.budgetUnavailable)
    }

    // 予算の確認を待つ間の変更も反映するよう、送る直前に最新の設定・同意・入力先を読み直す
    let latest = settingsStore.load()
    guard Self.stillSends(to: .claude, selected: selected, latest: latest) else {
      return local(.localEngineSelected)
    }
    let consent = currentConsent()
    // `RefinementRouter` は同期的に同意と判定を求めるため、ここで読み直した同意と判定した値を渡す。Router は予約を
    // 待った後にも求めるが、入力先はメインスレッドでしか読めないため、予約の間（BudgetGuard への1回の切り替え）の
    // 変化はここでの読み直しと判定までしか反映しない
    let decision = Self.decide(sensitivity(), settings: latest)
    let outcome: RefinementOutcome
    do throws(CancellationError) {
      // 送信先は、Router が予算の予約まで済ませてプロバイダーを呼ぶ直前に知らせる
      outcome = try await router.refine(
        request, consent: { consent }, budget: budget, sensitivity: { decision },
        willSend: { await willSend(.claude) })
    } catch {
      // 送信後にキャンセルされても推定費用は記録されるため、保存の失敗は確かめる
      await noteUsagePersistence(of: budget.guard)
      throw error
    }
    await noteUsagePersistence(of: budget.guard)
    return Self.result(of: outcome)
  }

  /// Sign in with ChatGPT へ送る（#50）。予算は使わず、サインインとプラン利用の許可を確かめてから送る
  private func refineWithChatGPT(
    _ request: RefinementRequest, selected: CloudRefinementProvider, settings: AppSettings,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext,
    willSend: @escaping @MainActor @Sendable (CloudAIProviderKind) -> Void
  ) async throws(CancellationError) -> SessionRefinementResult {
    func local(_ reason: SessionRefinementRoute.LocalReason) -> SessionRefinementResult {
      SessionRefinementResult(text: localRefiner.refine(request), route: .localOnly(reason))
    }
    guard let chatGPTAccount,
      let configuration = try? ChatGPTPlanProvider.Configuration(
        model: settings.chatGPTRefinementModel)
    else { return local(.cloudUnavailable) }
    let provider = measured(makeChatGPTProvider(configuration, chatGPTAccount))
    guard currentConsent().allows(.textRefinement(provider.destination)) else {
      return local(.consentNotGranted)
    }
    // サインインしていない・プラン利用が許可されていなければ送らない（トークンの更新もしない）
    let status = await chatGPTAccount.status()
    if Task.isCancelled { throw CancellationError() }
    guard case .signedIn(_, let planUsage) = status, planUsage != .notGranted else {
      return local(.chatGPTNotSignedIn)
    }
    guard Self.decide(sensitivity(), settings: settings).allowsCloudTransmission else {
      return local(.sensitiveInput)
    }
    guard
      let router = try? RefinementRouter(
        provider: provider, localRefiner: localRefiner, timeout: timeout)
    else { return local(.cloudUnavailable) }

    // 状態の確認を待つ間の変更も反映するよう、送る直前に最新の設定・同意・入力先を読み直す
    let latest = settingsStore.load()
    guard Self.stillSends(to: .chatGPTSignIn, selected: selected, latest: latest) else {
      return local(.localEngineSelected)
    }
    let consent = currentConsent()
    let decision = Self.decide(sensitivity(), settings: latest)
    // トークン課金ではないため予算は渡さない（`ChatGPTPlanProvider.isTokenBilled == false`）
    let outcome = try await router.refine(
      request, consent: { consent }, budget: nil, sensitivity: { decision },
      willSend: { await willSend(.chatGPT) })
    return Self.result(of: outcome)
  }

  /// OpenAI API キー方式で送る（#58）。Claude と同じく、予算の上限を確かめてから送る（AI-04, AI-05）
  private func refineWithOpenAI(
    _ request: RefinementRequest, selected: CloudRefinementProvider, settings: AppSettings,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext,
    willSend: @escaping @MainActor @Sendable (CloudAIProviderKind) -> Void
  ) async throws(CancellationError) -> SessionRefinementResult {
    func local(_ reason: SessionRefinementRoute.LocalReason) -> SessionRefinementResult {
      SessionRefinementResult(text: localRefiner.refine(request), route: .localOnly(reason))
    }
    guard !hasUsagePersistenceFailure else { return local(.budgetUnavailable) }
    guard let openAIAPIKeyStore,
      let configuration = try? OpenAIProvider.Configuration(model: settings.openAIRefinementModel)
    else { return local(.cloudUnavailable) }
    // Sign in with ChatGPT と同じ送信先（OpenAI）への同意で確かめる。同意がなければ Keychain も読まない
    guard currentConsent().allows(.textRefinement(.chatGPT)) else {
      return local(.consentNotGranted)
    }
    // キーがなければ予算の確認も送信もしない
    let apiKey: APIKey
    do throws(APIKeyStoreError) {
      guard let stored = try openAIAPIKeyStore.load() else { return local(.apiKeyNotSet) }
      apiKey = stored
    } catch {
      return local(.apiKeyUnavailable)
    }
    let provider = measured(makeOpenAIProvider(configuration, apiKey))
    // 送信先の申告が違えば、別の送信先への同意で送ってしまうため送らない（AC-06）
    guard provider.destination == .chatGPT, provider.isTokenBilled else {
      return local(.cloudUnavailable)
    }
    guard Self.decide(sensitivity(), settings: settings).allowsCloudTransmission else {
      return local(.sensitiveInput)
    }
    guard
      let router = try? RefinementRouter(
        provider: provider, localRefiner: localRefiner, timeout: timeout)
    else { return local(.cloudUnavailable) }
    guard
      let budget = await makeBudget(
        settings: settings, model: configuration.model,
        maxOutputTokens: configuration.maxOutputTokens, request: request)
    else {
      if Task.isCancelled { throw CancellationError() }
      return local(.budgetUnavailable)
    }

    // 予算の確認を待つ間の変更も反映するよう、送る直前に最新の設定・同意・入力先を読み直す
    let latest = settingsStore.load()
    guard Self.stillSends(to: .openAIAPIKey, selected: selected, latest: latest) else {
      return local(.localEngineSelected)
    }
    let consent = currentConsent()
    let decision = Self.decide(sensitivity(), settings: latest)
    let outcome: RefinementOutcome
    do throws(CancellationError) {
      outcome = try await router.refine(
        request, consent: { consent }, budget: budget, sensitivity: { decision },
        willSend: { await willSend(.chatGPT) })
    } catch {
      // 送信後にキャンセルされても推定費用は記録されるため、保存の失敗は確かめる
      await noteUsagePersistence(of: budget.guard)
      throw error
    }
    await noteUsagePersistence(of: budget.guard)
    return Self.result(of: outcome)
  }

  /// 送る直前の最新の設定でも `provider` へ送ってよいか。クラウド AI と最初に選んだ送信先が選ばれたままで、
  /// 切り替え先へ送るときは切り替えの設定も残っているときだけ
  private static func stillSends(
    to provider: CloudRefinementProvider, selected: CloudRefinementProvider, latest: AppSettings
  ) -> Bool {
    guard latest.refinementEngine == .cloudAI, latest.cloudRefinementProvider == selected else {
      return false
    }
    return provider == selected || latest.cloudRefinementFallbackEnabled
  }

  /// `RefinementRouter` の結果を、セッションの整形の経路にする
  private static func result(of outcome: RefinementOutcome) -> SessionRefinementResult {
    switch outcome.source {
    case .cloud:
      return SessionRefinementResult(text: outcome.text, route: .cloud)
    case .raw:
      return SessionRefinementResult(text: outcome.text, route: .localOnly(.rawMode))
    case .localFallback(.consentNotGranted):
      // 送る直前に同意が撤回されていた。送っていない
      return SessionRefinementResult(text: outcome.text, route: .localOnly(.consentNotGranted))
    case .localFallback(.sensitiveInputSuppressed):
      return SessionRefinementResult(text: outcome.text, route: .localOnly(.sensitiveInput))
    case .localFallback(let reason):
      return SessionRefinementResult(text: outcome.text, route: .cloudFallback(reason))
    }
  }

  /// スタイルの判定に使う、前面のブラウザで表示中のページのホスト名（CTX-02）。
  /// サイト単位の識別が許可されていない・サイト別の上書きがない（`needsSiteHost` が `false`）・前面アプリが
  /// 特定できないときは、`reader` を呼ばずに `nil`（アプリ別のスタイルを使う）
  static func siteHost(
    reader: any FrontmostSiteHostReading, resolver: SiteStyleResolver, frontmostApp: String?
  ) -> SiteHost? {
    guard resolver.needsSiteHost, let frontmostApp else { return nil }
    return reader.siteHost(inFrontmostApp: frontmostApp)
  }

  /// 計測器があれば、送信先の `refine` を `LLMComplete` の区間として計測する
  private func measured(_ provider: any AIProvider) -> any AIProvider {
    guard let measurer else { return provider }
    return PerfMeasuredAIProvider(base: provider, measurer: measurer)
  }

  /// 同意の画面（`ConsentSettingsController`）が保存した最新の同意状態
  private func currentConsent() -> ConsentState {
    ConsentSettingsController(store: settingsStore).currentConsent()
  }

  /// 機密入力の判定。利用者の除外アプリは設定から読む
  private static func decide(
    _ context: SensitiveInputContext, settings: AppSettings
  ) -> SensitiveInputDecision {
    SensitiveInputPolicy(excludedApps: Set(settings.excludedApps)).decide(context)
  }

  /// 保存した辞書。読めない・組み立てられない（競合するルールが保存されているなど）場合は `nil`
  private func loadDictionary() async -> UserDictionary? {
    guard let database = try? await database() else { return nil }
    return await Task.detached {
      guard let contents = try? DictionaryStore(database: database).contents() else { return nil }
      return try? DictionaryEditorModel.dictionary(from: contents)
    }.value
  }

  /// 今月の予算判定に使う `BudgetGuard` を、保存済みの累計から作る（AI-04, AI-05）。
  /// Claude と OpenAI API キー方式で同じ月次予算・単価表・累計を使う。`model` は単価表で引くモデル名、
  /// `maxOutputTokens` は見込みの出力の上限。
  /// 予算・単価表が未設定、通貨が一致しない、累計を読めない場合は `nil`（送らない）
  private func makeBudget(
    settings: AppSettings, model: String, maxOutputTokens: Int, request: RefinementRequest
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
      guard: budgetGuard, model: model,
      expectedUsage: Self.expectedUsage(for: request, maxOutputTokens: maxOutputTokens),
      month: cost.month)
  }

  private func noteUsagePersistence(of budgetGuard: BudgetGuard) async {
    if await budgetGuard.hasPersistenceFailure {
      hasUsagePersistenceFailure = true
    }
  }

  /// 送信前に予約する見込みの使用量。少なめに見積もらないよう、入力はプロンプトのバイト数（1トークン1バイト以上）に
  /// 余裕を足し、出力は上限（max_tokens）にする
  static func expectedUsage(for request: RefinementRequest, maxOutputTokens: Int) -> TokenUsage {
    let promptBytes =
      RefinementPromptBuilder().build(request).map { $0.system.utf8.count + $0.user.utf8.count }
      ?? request.text.utf8.count
    return TokenUsage(inputTokens: promptBytes + 64, outputTokens: maxOutputTokens)
  }
}

/// 整形の結果と、どの経路で整形したか。
struct SessionRefinementResult: Hashable, Sendable {
  /// 挿入する本文
  let text: String
  let route: SessionRefinementRoute
}

// 本文をログに出さないよう、文字列表現とリフレクションには経路と文字数だけを出す。
extension SessionRefinementResult: CustomStringConvertible, CustomReflectable {
  var description: String {
    "SessionRefinementResult(route: \(route), length: \(text.count))"
  }

  var customMirror: Mirror {
    Mirror(self, children: ["route": route, "length": text.count])
  }
}

/// 整形の経路（4.1節, AC-06）。
enum SessionRefinementRoute: Hashable, Sendable {
  /// 送らず、ローカル整形（Raw / Local Basic）だけを使った
  case localOnly(LocalReason)
  /// クラウド整形の応答が検証を通った
  case cloud
  /// クラウドへ送ろうとしたが、ローカル整形の結果に退避した（予算超過・失敗・検証失敗・上限時間の超過など）
  case cloudFallback(RefinementFallbackReason)

  /// 送らなかった理由
  enum LocalReason: Hashable, Sendable {
    /// Raw モード
    case rawMode
    /// 整形の処理系に Local Basic を選んでいる（既定）
    case localEngineSelected
    /// クラウド整形の設定（モデル名など）を使えない
    case cloudUnavailable
    /// 選んだ送信先（Claude・ChatGPT）への整形の送信に同意していない
    case consentNotGranted
    /// API キー（Claude、または OpenAI API キー方式の OpenAI）が保存されていない
    case apiKeyNotSet
    /// API キーを読み出せない（Mac のロック中・署名のないビルドなど）
    case apiKeyUnavailable
    /// 入力先が機密入力、または判定できない
    case sensitiveInput
    /// 予算上限を確かめられない（予算・単価表が未設定、通貨の不一致、累計を読み書きできない）
    case budgetUnavailable
    /// Sign in with ChatGPT でサインインしていない、またはプラン利用が許可されていない（#50）
    case chatGPTNotSignedIn
  }
}

extension CloudRefinementProvider {
  /// 失敗時に切り替える先（AI-04）。切り替えないなら `nil`。
  ///
  /// 切り替えの設定は「もう一方」を選ぶ1つのオン・オフで、Claude と Sign in with ChatGPT の2つの間だけで使う。
  /// OpenAI API キー方式へは切り替えない（AI-01。Sign in with ChatGPT からは同じ OpenAI の別方式になり、
  /// Claude からは「もう一方」が2つになって決められない）。OpenAI API キー方式を選んだときも切り替えない
  /// （Sign in with ChatGPT へは AI-01 で切り替えず、Claude へ切り替えるかは切り替え先を選ぶ設定がないため決めない）
  fileprivate var alternative: CloudRefinementProvider? {
    switch self {
    case .claude: .chatGPTSignIn
    case .chatGPTSignIn: .claude
    case .openAIAPIKey: nil
    }
  }
}

extension HUDRefinementMode {
  /// 保存した整形モード（TXT-01）。HUD のチップに出す
  init(_ setting: RefinementModeSetting) {
    switch setting {
    case .raw: self = .raw
    case .natural: self = .natural
    case .structured: self = .structured
    }
  }
}

extension RefinementMode {
  /// 保存した整形モード（TXT-01）
  init(_ setting: RefinementModeSetting) {
    switch setting {
    case .raw: self = .raw
    case .natural: self = .natural
    case .structured: self = .structured
    }
  }
}
