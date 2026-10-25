import UtterCore

/// クラウド整形が失敗したとき、明示的な許可がある場合に限って別のクラウドプロバイダーへ切り替える（4.1節, AI-04）。
///
/// 各送信先への送信は `RefinementRouter` で1回ずつ行い、同意・機密入力の判定・予算・上限時間・応答の検証・退避はそちらに従う。
/// 機密入力で送信を抑止した場合（7章, AC-12）は、別の送信先へも切り替えない。
/// 自動フォールバックへの同意（`ConsentScope.crossProviderFallback`）がなければ、`RefinementRouter` と同じく
/// 最初の送信先へ1回だけ送信し、失敗したらローカル整形の結果に退避する。
/// 同意があっても、切り替え元と切り替え先の両方への整形の同意がない送信先は飛ばす（`ConsentState.allowsFallback`）。
/// 切り替えるのは、課金されていない失敗（認証失効・利用枠不足・予算超過）のときだけで、
/// 課金されている可能性がある失敗（上限時間の超過・ネットワークの失敗・応答の解釈失敗・キャンセル・検証失敗）では切り替えない。
/// 同じ送信先へは再送しない。
/// すべての送信先で整形できなければ、最後に送信した結果（ローカル整形への退避）を返す。
public struct CloudFallbackRouter: Sendable {
  public let localRefiner: any LocalRefiner
  public let validator: RefinementValidator
  /// 送信先ごとの応答待ちの上限時間。切り替えるたびに、送信先ごとにこの時間まで待つ
  public let timeout: Duration

  public init(
    localRefiner: any LocalRefiner = RawRefiner(),
    validator: RefinementValidator = RefinementValidator(),
    timeout: Duration = RefinementRouter.defaultTimeout
  ) throws(RefinementRouterError) {
    guard timeout > .zero else {
      throw .nonPositiveTimeout
    }
    self.localRefiner = localRefiner
    self.validator = validator
    self.timeout = timeout
  }

  /// 発話を整形する。
  ///
  /// - Parameters:
  ///   - consent: 最新の同意状態を返す（AC-06, AI-04）。送信先ごとに、送信を判断する直前に呼ぶ。
  ///     最初の送信先の応答を待つ間に同意が撤回されたら、切り替え先へ送らない。
  ///     同期的に呼ぶため、メインスレッドを待たずに返す（最新の同意状態を保持しておき、それを返すなど）
  ///   - primary: 最初に送信する、利用者が選んだ送信先
  ///   - fallbacks: 切り替えを許可されている場合に、順に試す送信先。送信済みの送信先と同じ送信先は飛ばし、再送しない
  ///   - sensitivity: その時点の入力先で判定し直した結果（7章, AC-12）。送信先ごとに `RefinementRouter.refine` へ渡し、
  ///     そちらが送信の前に呼ぶ。確認を省略できないよう既定値は持たせない
  /// - Throws: 呼び出し元の Task がキャンセルされた場合。キャンセル後は次の送信先へ送らない
  public func refine(
    _ request: RefinementRequest,
    consent: @Sendable () -> ConsentState,
    primary: RefinementRoute,
    fallbacks: [RefinementRoute],
    sensitivity: @Sendable () -> SensitiveInputDecision
  ) async throws(CancellationError) -> RefinementOutcome {
    var outcome = try await router(for: primary).refine(
      request, consent: consent(), budget: primary.budget, sensitivity: sensitivity)
    var source = primary.provider.destination
    var attempted: Set<CloudAIProviderKind> = [source]
    for route in fallbacks {
      guard Self.allowsFallback(after: outcome) else {
        return outcome
      }
      if Task.isCancelled {
        throw CancellationError()
      }
      let destination = route.provider.destination
      let current = consent()
      guard !attempted.contains(destination),
        current.allowsFallback(from: source, to: destination)
      else {
        continue
      }
      outcome = try await router(for: route).refine(
        request, consent: current, budget: route.budget, sensitivity: sensitivity)
      source = destination
      attempted.insert(destination)
    }
    return outcome
  }

  /// 別のクラウドプロバイダーへ切り替えてよい結果か。
  ///
  /// 課金されない失敗（`AIProviderError.isUnbilled`。`BudgetGuard.resolve` が予算の予約を取り消す失敗）に限る。
  /// 課金されている可能性がある失敗で切り替えると二重に課金されうるため、ローカル整形の結果を使う。
  /// 呼び出し元がキャンセルしていないのにプロバイダーが `.cancelled` を返した場合も、課金されている可能性があるため切り替えない。
  /// 検証失敗は課金済みで、入力が原因のことが多く別の送信先でも同じ結果になりやすいため切り替えない。
  /// 機密入力による抑止は送信先によらないため切り替えない。
  private static func allowsFallback(after outcome: RefinementOutcome) -> Bool {
    switch outcome.source {
    case .cloud, .raw:
      false
    case .localFallback(let reason):
      switch reason {
      case .providerFailed(let error):
        error.isUnbilled
      case .validationFailed, .consentNotGranted, .sensitiveInputSuppressed:
        false
      }
    }
  }

  private func router(for route: RefinementRoute) -> RefinementRouter {
    // timeout は init で確認済みのため、生成は失敗しない。
    guard
      let router = try? RefinementRouter(
        provider: route.provider, localRefiner: localRefiner, validator: validator,
        timeout: timeout)
    else {
      preconditionFailure("timeout は init で正の値と確認済み")
    }
    return router
  }
}

/// `CloudFallbackRouter` で試す送信先と、その送信先の予算上限の設定（AI-04, AI-05）。
public struct RefinementRoute: Sendable {
  public let provider: any AIProvider
  /// 送信先ごとの予算上限の設定。`nil` はトークン課金ではない送信先（Sign in with ChatGPT など）に限る
  public let budget: RefinementBudget?

  /// - Throws: Claude への送信先で予算上限の設定がない場合（AI-04）。切り替え先も含め、Claude へは必ず予算を確認して送る
  public init(provider: any AIProvider, budget: RefinementBudget?) throws(RefinementRouteError) {
    if provider.destination == .claude, budget == nil {
      throw .budgetRequired
    }
    self.provider = provider
    self.budget = budget
  }
}

public enum RefinementRouteError: Error, Hashable, Sendable {
  /// 予算上限を守る送信先（Claude）に予算上限の設定がない
  case budgetRequired
}
