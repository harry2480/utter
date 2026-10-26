import Foundation
import UtterAI
import UtterCore
import UtterPersistence

/// iOS 本体アプリのクラウド整形の結線（iOS-10, AC-06, AC-12, AI-04）。
///
/// 整形のたびに次の順で確かめ、どれかが欠ければ送信せずにローカル整形（Local Basic）だけを使う。
/// 1. 保存済みの最新の設定で、整形の処理系にクラウド AI を選んでいる（AI-03。既定は Local Basic）
/// 2. Claude への整形の送信に同意している（AC-06）
/// 3. API キーが保存されていて読み出せる（AC-12）
/// 4. 予算上限を確かめられる（月次予算・単価表・使用量の累計, AI-04）
///
/// 送信の直前には `RefinementRouter` が機密入力の判定（`sensitivity`）を確かめ、送信できなければローカル整形に退避する（7章, AC-12）。
///
/// すべてそろえば `RefinementRouter` 経由で Claude へ1回だけ送信し、失敗・検証失敗・上限時間の超過は
/// ローカル整形の結果に退避する（4.1節）。処理系の選択と同意は送信の直前にもう一度読み、変更をすぐに反映する。
/// `AppSettingsStore` が `Sendable` でないため、`@MainActor` から使う。
@MainActor
public struct CloudRefinement {
  /// 送信先のプロバイダーを作る。本番は `ClaudeProvider(apiKeyStore:configuration:)`、テストは Stub を返す
  public typealias MakeProvider =
    @Sendable (ClaudeProvider.Configuration, any APIKeyStore) -> any AIProvider

  private let settingsStore: AppSettingsStore
  private let apiKeyStore: any APIKeyStore
  private let budgetSource: any CloudRefinementBudgetSource
  private let makeProvider: MakeProvider
  private let timeout: Duration
  private let date: @Sendable () -> Date
  private let sensitivity: @Sendable () -> SensitiveInputDecision

  /// - Parameters:
  ///   - settingsStore: 同意状態・モデル名・予算の設定の保存先。同意の画面と同じものを渡す
  ///   - apiKeyStore: Claude API キーの保存先（本番は本体アプリの Keychain）。API キーの設定画面と同じものを渡す
  ///   - budgetSource: 予算上限の確認と推定費用の記録
  ///   - makeProvider: 送信先のプロバイダー
  ///   - timeout: クラウド整形の応答待ちの上限時間。0 以下なら既定値を使う
  ///   - date: 実時刻（費用を計上する月の判定）
  ///   - sensitivity: 送信前に確かめる機密入力の判定（7章, AC-12）。本番は `ownAppSensitivity()`（自アプリの画面で録音・整形するため、
  ///     入力欄・セキュア入力は `off`、アプリは自アプリの bundle ID で判定する）
  public init(
    settingsStore: AppSettingsStore,
    apiKeyStore: any APIKeyStore,
    budgetSource: any CloudRefinementBudgetSource,
    makeProvider: @escaping MakeProvider = { configuration, store in
      ClaudeProvider(apiKeyStore: store, configuration: configuration)
    },
    timeout: Duration = RefinementRouter.defaultTimeout,
    date: @escaping @Sendable () -> Date = { Date() },
    sensitivity: @escaping @Sendable () -> SensitiveInputDecision =
      CloudRefinement
      .ownAppSensitivity()
  ) {
    self.settingsStore = settingsStore
    self.apiKeyStore = apiKeyStore
    self.budgetSource = budgetSource
    self.makeProvider = makeProvider
    self.timeout = timeout > .zero ? timeout : RefinementRouter.defaultTimeout
    self.date = date
    self.sensitivity = sensitivity
  }

  /// iOS 本体アプリの機密入力の判定（7章, AC-12）。
  ///
  /// 本体アプリは自分の画面で録音・整形するため、入力欄のセキュア属性とシステムのセキュア入力は `off`、
  /// アプリは自アプリの bundle ID で判定する。bundle ID を取得できなければ `SensitiveInputPolicy` が判定不能として抑止する（安全側）。
  /// 判定は起動中に変わらないため一度だけ作り、送信前の確認ではその結果を返す。
  /// - Parameter bundleIdentifier: 自アプリの bundle ID。既定は `Bundle.main.bundleIdentifier`
  public nonisolated static func ownAppSensitivity(
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> @Sendable () -> SensitiveInputDecision {
    let decision = SensitiveInputPolicy().decide(
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: bundleIdentifier))
    return { decision }
  }

  /// 発話を整形する。
  ///
  /// - Throws: 呼び出し元の Task がキャンセルされた場合。キャンセルされたセッションの結果は使わない
  public func refine(
    _ request: RefinementRequest, localRefiner: any LocalRefiner
  ) async throws(CancellationError) -> SessionRefinementResult {
    func local(_ reason: SessionRefinementRoute.LocalReason) -> SessionRefinementResult {
      SessionRefinementResult(text: localRefiner.refine(request), route: .localOnly(reason))
    }
    // Raw は整形しないため送信しない
    guard request.mode != .raw else { return local(.rawMode) }

    let settings = settingsStore.load()
    guard settings.refinementEngine == .cloudAI else { return local(.localEngineSelected) }
    guard let configuration = try? ClaudeProvider.Configuration(model: settings.refinementModel)
    else {
      return local(.cloudUnavailable)
    }
    let provider = makeProvider(configuration, apiKeyStore)
    guard settings.consentState.allows(.textRefinement(provider.destination)) else {
      return local(.consentNotGranted)
    }
    // キーがなければ予算の予約も送信もしない。キーの値はここでは使わない（送信時にプロバイダーが読み出す）
    let hasKey: Bool
    do {
      hasKey = try apiKeyStore.load() != nil
    } catch {
      return local(.apiKeyUnavailable)
    }
    guard hasKey else { return local(.apiKeyNotSet) }
    guard
      let router = try? RefinementRouter(
        provider: provider, localRefiner: localRefiner, timeout: timeout)
    else {
      return local(.cloudUnavailable)
    }

    let budget: CloudRefinementBudget
    switch await budgetSource.begin(
      model: configuration.model, maxOutputTokens: configuration.maxTokens, request: request,
      settings: settings, at: date())
    {
    case .ready(let ready):
      budget = ready
    case .unavailable(let reason):
      if Task.isCancelled { throw CancellationError() }
      return local(.budgetUnavailable(reason))
    }
    // 予算の確認を待つ間の変更も反映するよう、送信の直前に最新の設定を読み直す
    let latest = settingsStore.load()
    guard latest.refinementEngine == .cloudAI else {
      await budget.finish()
      return local(.localEngineSelected)
    }
    // `AppSettingsStore` は `Sendable` でないため、読み直した同意状態を渡す
    let consentState = latest.consentState
    let outcome: RefinementOutcome
    do throws(CancellationError) {
      outcome = try await router.refine(
        request, consent: { consentState }, budget: budget.budget, sensitivity: sensitivity)
    } catch {
      // 送信後にキャンセルされても課金されている可能性があるため、推定費用は記録する
      await budget.finish()
      throw error
    }
    await budget.finish()

    switch outcome.source {
    case .cloud:
      return SessionRefinementResult(text: outcome.text, route: .cloud)
    case .raw:
      return SessionRefinementResult(text: outcome.text, route: .localOnly(.rawMode))
    case .localFallback(.consentNotGranted):
      return SessionRefinementResult(text: outcome.text, route: .localOnly(.consentNotGranted))
    case .localFallback(let reason):
      return SessionRefinementResult(text: outcome.text, route: .cloudFallback(reason))
    }
  }
}

/// 整形の結果と、どの経路で整形したか。
public struct SessionRefinementResult: Hashable, Sendable {
  /// 保存する本文
  public let text: String
  public let route: SessionRefinementRoute

  public init(text: String, route: SessionRefinementRoute) {
    self.text = text
    self.route = route
  }
}

// 本文をログに出さないよう、文字列表現とリフレクションには経路と文字数だけを出す。
extension SessionRefinementResult: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "SessionRefinementResult(route: \(route), length: \(text.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["route": route, "length": text.count])
  }
}

/// 整形の経路（4.1節, AC-06）。
public enum SessionRefinementRoute: Hashable, Sendable {
  /// 送信せず、ローカル整形だけを使った
  case localOnly(LocalReason)
  /// クラウド整形の応答が検証を通った
  case cloud
  /// クラウドへ送ろうとしたが、ローカル整形の結果に退避した（予算超過・失敗・検証失敗・上限時間の超過）
  case cloudFallback(RefinementFallbackReason)

  /// 送信しなかった理由
  public enum LocalReason: Hashable, Sendable {
    /// クラウド整形を結線していない
    case cloudNotConfigured
    /// Raw モード
    case rawMode
    /// 整形の処理系に Local Basic を選んでいる（既定）
    case localEngineSelected
    /// クラウド整形の設定（モデル名など）を使えない
    case cloudUnavailable
    /// Claude への整形の送信に同意していない
    case consentNotGranted
    /// API キーが保存されていない
    case apiKeyNotSet
    /// API キーを読み出せない（端末のロック中・保存先の不具合など）
    case apiKeyUnavailable
    /// 予算上限を確かめられない
    case budgetUnavailable(CloudBudgetUnavailableReason)
  }
}
