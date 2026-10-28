import Foundation
import Observation
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// メニューバーのメニューの状態の表示と、よく変える設定の切り替え（#197, 2.2節, TXT-01, AI-03, AI-05, AC-06, CTX-01, PERM-03）。
///
/// 入力モード・文体（整形モード）・整形の実行先は、設定画面と同じ `AppSettingsStore` に保存する。
/// 保存は保存先の最新の値を基準にし、メニューで変える項目だけを書き換える（ほかの画面で変えた同意などを残す）。
/// 設定画面などで保存された値は `reload()` で読み直す（UserDefaults の変更の通知で呼ぶ）。
/// 整形の実行先の選択肢と選べるかは、設定画面と同じ `RefinementProviderChoice` に従う。
/// 選んでも、送るかは送る直前に同意・API キー（またはサインイン）・予算で決める（`SessionRefinementPipeline`）。
/// 同意のない送信先を選んだときは、同意の画面へ案内する（`ProviderSelection.consentRequired`）。ここで同意は変えない。
/// 推定費用は設定画面と同じ `CloudCostBridge` で作り、累計はメインスレッドの外で読む。
@MainActor
@Observable
final class MenuBarModel {
  /// 整形の実行先を選んだ結果
  enum ProviderSelection: Equatable {
    /// 保存した。送信先なら送信の同意もある
    case saved
    /// 保存したが、送信の同意がない。同意の画面へ案内する（同意がない間は送らない, AC-06）
    case consentRequired
    /// 選べない選択肢（準備中）。保存しない
    case notSelectable
    /// 保存できなかった
    case saveFailed
  }

  /// 前面のアプリ（CTX-01）。メニューに自動スタイルを出すためだけに使い、保存・送信しない
  struct FrontmostApp: Equatable, Sendable {
    let bundleID: String?
    let name: String
  }

  /// 最後に読み込んだ・保存した設定
  private(set) var settings: AppSettings
  /// 今月の推定費用（AI-05）。表示の値は設定画面と同じ
  private(set) var cost: SettingsModel.CostState = .loading
  /// 音声認識モデルの取得状態（PERM-03）。まだ確かめていない・OS が管理するモデルを使わないエンジンなら `nil`
  private(set) var speechModelAvailability: UtterSpeech.SpeechModelAvailability?
  /// 前面のアプリ。分からなければ `nil`
  private(set) var frontmostApp: FrontmostApp?
  /// 直前のメニューからの保存に失敗したか
  private(set) var saveFailed = false
  /// 使っているローカルの STT エンジン。未選択なら `nil`（`AppComposition.selectedEngine()`）
  let sttEngine: STTEngineKind?

  private let store: AppSettingsStore
  private let openUsageStore: @Sendable () async throws -> MonthlyUsageStore
  /// 一度開いた保存先を使い回す（読み直すたびにデータベースを開き直さない）
  private var usageStore: MonthlyUsageStore?
  private let modelAssets: (any SpeechModelAssets)?
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  /// 推定費用の読み込みの世代。古い読み込みの結果で新しい表示を上書きしない
  private var costGeneration = 0
  /// モデルの状態の確認の世代。後から始めた確認の結果だけを反映する
  private var speechModelGeneration = 0

  /// - Parameters:
  ///   - store: 設定の保存先。設定画面と同じ保存先を渡す
  ///   - openUsageStore: 推定費用の累計の保存先を開く。設定画面と同じデータベースを使う
  ///   - sttEngine: 使っているローカルの STT エンジン。未選択なら `nil`
  ///   - modelAssets: モデルの状態の確認の口。OS が管理するモデルを使わないエンジンなら `nil`。
  ///     状態の確認だけに使い、取得はしない（取得は設定画面のボタンからだけ）
  init(
    store: AppSettingsStore,
    openUsageStore: @escaping @Sendable () async throws -> MonthlyUsageStore,
    sttEngine: STTEngineKind?,
    modelAssets: (any SpeechModelAssets)?,
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .current
  ) {
    self.store = store
    self.openUsageStore = openUsageStore
    self.sttEngine = sttEngine
    self.modelAssets = modelAssets
    self.now = now
    self.calendar = calendar
    settings = store.load()
  }

  // MARK: 読み直し

  /// 保存済みの値を読み直す。変わったら `true`
  @discardableResult
  func reload() -> Bool {
    let latest = store.load()
    guard latest != settings else { return false }
    settings = latest
    return true
  }

  /// 前面のアプリを置き換える
  func updateFrontmostApp(_ app: FrontmostApp?) {
    frontmostApp = app
  }

  // MARK: 入力モード（2.2節）

  /// メニューで選べる入力モード。Realtime Direct（実験機能）は設定画面で選んでいるときだけ並べる
  var inputModeChoices: [InputMode] {
    let choices: [InputMode] = [.instant, .realtimePreview]
    return settings.inputMode == .realtimeDirect ? choices + [.realtimeDirect] : choices
  }

  /// 入力モードを保存する。進行中のセッションは変えず、次の録音から使う。保存できたら `true`
  @discardableResult
  func select(inputMode: InputMode) -> Bool {
    update { $0.inputMode = inputMode }
  }

  // MARK: 文体（TXT-01, CTX-01）

  /// 文体（整形モード）を保存する。保存できたら `true`
  @discardableResult
  func select(refinementMode: RefinementModeSetting) -> Bool {
    update { $0.refinementMode = refinementMode }
  }

  /// 前面のアプリに使う自動スタイル（CTX-01）。サイト別の上書き（CTX-02）は録音のときに判定するため、ここでは使わない
  func autoStyle(forBundleID bundleID: String?) -> RefinementStyle {
    settings.contextStyleResolver.style(forBundleID: bundleID)
  }

  // MARK: 整形の実行先（AI-01, AI-03, AC-06）

  /// 保存済みの整形の実行先
  var provider: RefinementProviderChoice {
    RefinementProviderChoice(
      engine: settings.refinementEngine, cloudProvider: settings.cloudRefinementProvider)
  }

  /// 整形の実行先を保存する。保存の内容は設定画面（`SettingsForm.applied(to:)`）と同じ。
  ///
  /// Local Basic を選んだときはクラウドの送信先を変えない。同意は変えず、同意がなければ `consentRequired` を返す
  func select(provider choice: RefinementProviderChoice) -> ProviderSelection {
    guard let engine = choice.engine else { return .notSelectable }
    let saved = update {
      $0.refinementEngine = engine
      if let cloudProvider = choice.cloudProvider {
        $0.cloudRefinementProvider = cloudProvider
      }
    }
    guard saved else { return .saveFailed }
    return hasConsent(for: choice) ? .saved : .consentRequired
  }

  /// 送信の同意があるか。文字を送らない選択肢は `true`
  func hasConsent(for choice: RefinementProviderChoice) -> Bool {
    guard let transmission = Self.transmission(of: choice) else { return true }
    return settings.consentState.allows(transmission)
  }

  /// 選択肢が文字を送る送信（同意の対象）。文字を送らない選択肢は `nil`
  static func transmission(of choice: RefinementProviderChoice) -> CloudTransmission? {
    switch choice {
    case .localBasic: nil
    case .claude: .textRefinement(.claude)
    // どちらの方式も OpenAI へ送るため、同意は同じ送信先として扱う
    case .chatGPTSignIn, .openAIAPIKey: .textRefinement(.chatGPT)
    }
  }

  /// 文字を外へ送る選択肢か
  static func sendsText(_ choice: RefinementProviderChoice) -> Bool {
    transmission(of: choice) != nil
  }

  // MARK: 推定費用（AI-05）

  /// 保存済みの設定で、今月の推定費用を読み直す
  func refreshCost() async {
    costGeneration += 1
    let generation = costGeneration
    let configuration: CloudCostBridge.Configuration
    do throws(CloudCostBridge.Unavailable) {
      configuration = try CloudCostBridge.configuration(for: settings, at: now(), in: calendar)
    } catch {
      cost = .unavailable(error)
      return
    }
    let openUsageStore = self.openUsageStore
    let usageStore = self.usageStore
    let result = await Task.detached {
      () -> (store: MonthlyUsageStore?, state: SettingsModel.CostState) in
      let opened: MonthlyUsageStore
      do {
        if let usageStore {
          opened = usageStore
        } else {
          opened = try await openUsageStore()
        }
      } catch {
        return (nil, .unreadable)
      }
      do {
        let summary = try CloudCostBridge.estimatedCostSummary(
          configuration: configuration, usageStore: opened)
        return (opened, .summary(summary))
      } catch let reason as CloudCostBridge.Unavailable {
        return (opened, .unavailable(reason))
      } catch {
        return (opened, .unreadable)
      }
    }.value
    if let store = result.store {
      self.usageStore = store
    }
    guard generation == costGeneration else { return }
    cost = result.state
  }

  // MARK: 音声認識モデル（PERM-03）

  /// モデルの取得状態を確かめ直す。ネットワークは使わず、取得もしない
  func refreshSpeechModel() async {
    guard let modelAssets else { return }
    speechModelGeneration += 1
    let generation = speechModelGeneration
    let value = await modelAssets.availability()
    guard generation == speechModelGeneration else { return }
    speechModelAvailability = value
  }

  // MARK: 保存

  /// 保存先の最新の値に `change` を反映して保存する。保存できたら `true`
  private func update(_ change: (inout AppSettings) -> Void) -> Bool {
    var latest = store.load()
    change(&latest)
    do {
      try store.save(latest)
    } catch {
      settings = store.load()
      saveFailed = true
      return false
    }
    settings = latest
    saveFailed = false
    return true
  }
}

// MARK: - メニューの文言

extension MenuBarModel {
  /// 推定値であることの注記（AI-05）
  static let costEstimateNote = "トークン使用量と単価表からの推定値です（請求額ではありません）"

  /// セッションの状態
  static func phaseTitle(_ phase: SessionPhase) -> String {
    switch phase {
    case .idle: "状態: 待機中"
    case .recording: "状態: 録音中"
    case .recognizing: "状態: 認識中"
    case .refining: "状態: 整形中"
    case .inserting: "状態: 入力中"
    case .error(let failure): "状態: \(failureName(failure))に失敗しました"
    }
  }

  private static func failureName(_ failure: SessionFailure) -> String {
    switch failure {
    case .recording: "録音"
    case .recognition: "認識"
    case .refinement: "整形"
    case .insertion: "入力"
    }
  }

  /// 入力モードの短い名前（メニューの見出し）
  static func inputModeName(_ mode: InputMode) -> String {
    switch mode {
    case .instant: "Instant"
    case .realtimePreview: "Realtime Preview"
    case .realtimeDirect: "Realtime Direct（実験機能）"
    }
  }

  /// 文体の短い名前（メニューの見出し）
  static func refinementModeName(_ mode: RefinementModeSetting) -> String {
    switch mode {
    case .raw: "Raw"
    case .natural: "Natural"
    case .structured: "Structured"
    }
  }

  /// 整形の実行先の短い名前（メニューの見出し）
  static func providerName(_ choice: RefinementProviderChoice) -> String {
    switch choice {
    case .localBasic: "Local Basic"
    case .claude: "Claude"
    case .chatGPTSignIn: "ChatGPT（Sign in with ChatGPT）"
    case .openAIAPIKey: "ChatGPT（OpenAI API キー方式）"
    }
  }

  /// 整形の実行先の選択肢の項目名。文字を送る先には「文字を送信」、同意がなければ同意が要ることを添える
  static func providerTitle(_ choice: RefinementProviderChoice, hasConsent: Bool) -> String {
    var notes: [String] = []
    if !sendsText(choice) {
      notes.append("オフライン")
    } else {
      notes.append("文字を送信")
      if !choice.isSelectable {
        notes.append("準備中")
      } else if !hasConsent {
        notes.append("同意が必要")
      }
    }
    return "\(providerName(choice))（\(notes.joined(separator: "・"))）"
  }

  /// 認識の状態（4章, PERM-03）
  static func speechRecognitionText(
    engine: STTEngineKind?, cloudEnabled: Bool, availability: UtterSpeech.SpeechModelAvailability?
  ) -> String {
    // クラウド STT は同意・API キー・予算がそろわなければ送らない（`CloudSpeechRecognitionPipeline`）
    if cloudEnabled { return "音声認識: クラウド（OpenAI へ音声を送る設定）" }
    switch engine {
    case nil: return "音声認識: 未設定"
    case .stub: return "音声認識: 固定の結果（開発用）"
    case .whisperKit: return "音声認識: WhisperKit"
    case .speechAnalyzer:
      return "音声認識: SpeechAnalyzer（モデル: \(modelStatus(availability))）"
    }
  }

  private static func modelStatus(_ availability: UtterSpeech.SpeechModelAvailability?) -> String {
    switch availability {
    case nil: "確認中"
    case .unsupported: "この Mac・言語では使えません"
    case .notInstalled: "未取得"
    case .downloading: "取得中"
    case .installed: "取得済み"
    }
  }

  /// 今月の推定費用と上限（AI-05）。推定値であることは `costEstimateNote` で添える
  static func costText(_ state: SettingsModel.CostState, locale: Locale = .current) -> String {
    switch state {
    case .loading:
      return "今月の推定費用: 確認中"
    case .summary(let summary):
      let style = Decimal.FormatStyle.Currency(code: summary.currency.code, locale: locale)
      let spent = summary.estimatedSpent.formatted(style)
      let limit = summary.limitAmount.formatted(style)
      return "今月の推定費用: \(spent) / 上限 \(limit)"
    case .unavailable(let reason):
      return "今月の推定費用: \(unavailableText(reason))"
    case .unreadable:
      return "今月の推定費用: 記録を読み込めません"
    }
  }

  private static func unavailableText(_ reason: CloudCostBridge.Unavailable) -> String {
    switch reason {
    case .budgetNotSet: "月次予算が未設定"
    case .priceTableIncomplete: "単価表の通貨か更新日が未設定"
    case .currencyMismatch: "予算と単価表の通貨が異なるため表示できません"
    case .invalidMonth: "表示できません"
    case .usageInOtherCurrency: "別の通貨の記録があるため表示できません"
    }
  }
}
