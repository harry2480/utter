import Foundation
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// 録音のセッションのクラウド STT（4章, AC-06, AI-04, AI-05, CTX-03, #188, MVP 外）。
///
/// 設定画面の「音声認識」タブでクラウド STT を選んだ（`AppSettings.cloudSpeechRecognitionEnabled`、既定は無効）セッションで、
/// 録音を始める前に次がすべてそろったときだけ `OpenAISpeechRecognizer` を作る。どれかが欠ければ作らず（送らず）、理由を返す。
/// 1. クラウド STT への音声の送信（`.transmission(.speechRecognition)`）に同意している（AC-06。整形・選択テキストの
///    送信への同意とは別。同意の画面が保存した最新の値を読む）
/// 2. OpenAI API キーが保存されていて読み出せる（Keychain、本デバイス限定・iCloud 同期なし。Claude API キーとは別）
/// 3. 予算上限を確かめられる（AI-04, AI-05。整形と同じ月次予算・単価表・今月の累計から `BudgetGuard` を作る。
///    単価表にクラウド STT のモデル（`model`）の単価がなければ作らない）
///
/// 認識器は認識の開始時と送信の直前にも同意を読み直し（撤回されていれば送らない）、送信の直前に入力先の機密入力の判定もし直し
/// （録音中にパスワード欄・除外アプリなどへ移っていれば送らない, 7章, AC-12）、送信前に見込み費用を予約して、
/// 応答の使用量で推定費用を整形と同じ累計に記録する。送るのは録音音声とモデル名などの設定値だけで、
/// 辞書語・ウィンドウタイトル・入力欄の本文・URL は送らない（CTX-03）。
/// 推定費用の累計を保存できなかった（`BudgetGuard.hasPersistenceFailure`）後は、アプリを起動し直すまで送らない（安全側）。
/// 音声・認識テキスト・API キーはログに出さない。
@MainActor
final class CloudSpeechRecognitionPipeline: SessionCloudSpeechRecognizing {
  /// 認識器を作る。本番は `OpenAISpeechRecognizer`（実ネットワーク）、テストは Stub の送信部を使う
  typealias MakeRecognizer = @Sendable (RecognizerParts) -> any SpeechRecognizer

  /// 認識器を作るのに使う値。API キーは保存せず、作った認識器だけが持つ
  struct RecognizerParts: Sendable {
    let apiKey: APIKey
    let configuration: OpenAISpeechRecognizer.Configuration
    /// 最新の同意状態。認識器が認識の開始時と送信の直前に呼ぶ
    let consent: @Sendable () async -> ConsentState
    /// その時点の入力先の機密入力の判定。認識器が送信の直前に呼ぶ（7章, AC-12）
    let sensitivity: @Sendable () async -> SensitiveInputDecision
    let budget: SpeechRecognitionBudget
  }

  /// クラウド STT のモデル名（仮置き）。単価表の照合にも使う。設定画面で変えられるようにするかは #60 で決める
  nonisolated static let model = "gpt-4o-mini-transcribe"

  /// 音声1秒あたりの見込みの使用量（仮置き, AI-05）。応答に使用量がなければこの量で記録するため、少なめに見積もらない。
  /// 入力は音声トークン（1分あたり約1,000トークンの公表値に余裕を足す）、出力は認識テキスト（日本語の発話速度に余裕を足す）
  static let expectedUsagePerSecond = TokenUsage(inputTokens: 20, outputTokens: 10)

  private let settingsStore: AppSettingsStore
  private let apiKeyStore: any APIKeyStore
  private let database: @MainActor () async throws -> UtterDatabase
  private let makeRecognizer: MakeRecognizer
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  /// 推定費用の累計を保存できなかったか。一度でも失敗したら、以降は送らない
  private var hasUsagePersistenceFailure = false
  /// 直前に作った認識器の予算。次の準備で、推定費用の累計を保存できたかを確かめる
  private var lastBudgetGuard: BudgetGuard?

  /// - Parameters:
  ///   - settingsStore: クラウド STT の選択・予算・同意の保存先。設定画面・同意の画面と同じものを渡す
  ///   - apiKeyStore: OpenAI API キーの保存先。API キーの画面と同じものを渡す
  ///   - database: 推定費用の累計を保存するデータベース（整形と同じもの）
  ///   - now: 実時刻（費用を計上する月の判定）
  ///   - calendar: 費用を計上する月の判定に使う暦。設定画面の推定費用の表示と同じものを使う
  init(
    settingsStore: AppSettingsStore,
    apiKeyStore: any APIKeyStore,
    database: @escaping @MainActor () async throws -> UtterDatabase,
    makeRecognizer: @escaping MakeRecognizer = { parts in
      OpenAISpeechRecognizer(
        apiKey: parts.apiKey.value, configuration: parts.configuration, consent: parts.consent,
        sensitivity: parts.sensitivity, budget: parts.budget)
    },
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .current
  ) {
    self.settingsStore = settingsStore
    self.apiKeyStore = apiKeyStore
    self.database = database
    self.makeRecognizer = makeRecognizer
    self.now = now
    self.calendar = calendar
  }

  var isSelected: Bool {
    settingsStore.load().cloudSpeechRecognitionEnabled
  }

  func prepareRecognizer(
    sensitivity: @escaping @Sendable () async -> SensitiveInputDecision
  ) async -> CloudSpeechRecognitionPreparation {
    if let lastBudgetGuard, await lastBudgetGuard.hasPersistenceFailure {
      hasUsagePersistenceFailure = true
    }
    guard !hasUsagePersistenceFailure else { return .unavailable(.budgetUnavailable) }
    let settings = settingsStore.load()
    guard let configuration = try? OpenAISpeechRecognizer.Configuration(model: Self.model) else {
      return .unavailable(.configurationUnavailable)
    }
    guard currentConsent().allows(.speechRecognition) else {
      return .unavailable(.consentNotGranted)
    }
    // キーがなければ予算の確認も送信もしない
    let apiKey: APIKey
    do throws(APIKeyStoreError) {
      guard let stored = try apiKeyStore.load() else { return .unavailable(.apiKeyNotSet) }
      apiKey = stored
    } catch {
      return .unavailable(.apiKeyUnavailable)
    }
    guard let budget = await makeBudget(settings: settings, model: configuration.model) else {
      return .unavailable(.budgetUnavailable)
    }
    // 予算の確認を待つ間に撤回されていたら作らない（送信の直前にも認識器が読み直す）
    guard currentConsent().allows(.speechRecognition) else {
      return .unavailable(.consentNotGranted)
    }
    lastBudgetGuard = budget.guard
    let consent: @Sendable () async -> ConsentState = { [weak self] in
      // 作った側が先に解放されたら、未同意に倒す（AC-06）
      await self?.currentConsent() ?? ConsentState()
    }
    return .ready(
      makeRecognizer(
        RecognizerParts(
          apiKey: apiKey, configuration: configuration, consent: consent,
          sensitivity: sensitivity, budget: budget)))
  }

  /// 同意の画面（`ConsentSettingsController`）が保存した最新の同意状態
  private func currentConsent() -> ConsentState {
    ConsentSettingsController(store: settingsStore).currentConsent()
  }

  /// 今月の予算判定に使う `BudgetGuard` を、保存済みの累計から作る（AI-04, AI-05。整形と同じ）。
  /// 予算・単価表が未設定、単価表にモデルがない、通貨が一致しない、累計を読めない場合は `nil`（送らない）
  private func makeBudget(settings: AppSettings, model: String) async -> SpeechRecognitionBudget? {
    guard
      let cost = try? CloudCostBridge.configuration(for: settings, at: now(), in: calendar),
      cost.priceTable.price(for: model) != nil,
      let database = try? await database()
    else { return nil }
    let usageStore = MonthlyUsageStore(database: database)
    guard
      let budgetGuard = try? await Task.detached(operation: {
        try CloudCostBridge.makeBudgetGuard(configuration: cost, usageStore: usageStore)
      }).value
    else { return nil }
    let month = cost.month
    return SpeechRecognitionBudget(
      guard: budgetGuard, expectedUsagePerSecond: Self.expectedUsagePerSecond,
      currentMonth: { month })
  }
}

extension CloudSpeechRecognitionNotice {
  /// クラウド STT の認識の失敗を、HUD で知らせる種類にする。クラウド STT の失敗でなければ `nil`（理由を出さない）
  init?(_ error: SpeechRecognitionError) {
    switch error {
    case .consentNotGranted: self = .consentNotGranted
    case .audioLimitExceeded: self = .audioLimitExceeded
    case .sensitiveInput: self = .sensitiveInput
    case .budgetExceeded: self = .budgetExceeded
    case .timeout: self = .timeout
    case .authenticationExpired: self = .authenticationExpired
    case .quotaExceeded: self = .quotaExceeded
    case .networkUnavailable: self = .networkUnavailable
    case .invalidResponse: self = .invalidResponse
    case .modelUnavailable, .unsupportedAudioFormat, .engineFailed, .resourceLimited: return nil
    }
  }
}
