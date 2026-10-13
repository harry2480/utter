/// 選択されたクラウドプロバイダーへ1回だけ送信し、応答を検証して返す（4.1節, AC-16）。
///
/// 同意がない・失敗・上限時間の超過・検証失敗のときは、ローカル整形の結果に退避して発話を失わない。
/// 失敗しても再送や別のクラウドプロバイダーへの切り替えはしない（AI-04）。
public struct RefinementRouter: Sendable {
  /// クラウド整形の応答待ちの上限時間の既定値（暫定）
  public static let defaultTimeout: Duration = .seconds(10)

  public let provider: any AIProvider
  public let localRefiner: any LocalRefiner
  public let validator: RefinementValidator
  /// クラウド整形の応答待ちの上限時間
  public let timeout: Duration

  public init(
    provider: any AIProvider,
    localRefiner: any LocalRefiner = RawRefiner(),
    validator: RefinementValidator = RefinementValidator(),
    timeout: Duration = defaultTimeout
  ) throws(RefinementRouterError) {
    guard timeout > .zero else {
      throw .nonPositiveTimeout
    }
    self.provider = provider
    self.localRefiner = localRefiner
    self.validator = validator
    self.timeout = timeout
  }

  /// 発話を整形する。
  ///
  /// - Parameter cloudConsentGranted: クラウド整形への送信の同意。`false` ならプロバイダーを呼ばない（AC-06）
  /// - Throws: 呼び出し元の Task がキャンセルされた場合。キャンセルされたセッションの結果は使わないため退避しない
  public func refine(
    _ request: RefinementRequest,
    cloudConsentGranted: Bool
  ) async throws(CancellationError) -> RefinementOutcome {
    guard cloudConsentGranted else {
      return fallback(request, reason: .consentNotGranted)
    }
    if Task.isCancelled {
      throw CancellationError()
    }

    let result = await requestWithTimeout(request)
    if Task.isCancelled {
      throw CancellationError()
    }

    switch result {
    case .success(let response):
      if let failure = validator.validate(response.text, for: request) {
        return fallback(request, reason: .validationFailed(failure))
      }
      return RefinementOutcome(text: response.text, source: .cloud(usage: response.usage))
    case .failure(let error):
      return fallback(request, reason: .providerFailed(error))
    }
  }

  private func fallback(
    _ request: RefinementRequest,
    reason: RefinementFallbackReason
  ) -> RefinementOutcome {
    RefinementOutcome(text: localRefiner.refine(request), source: .localFallback(reason))
  }

  /// プロバイダーの応答と上限時間を競わせる。先に終わった方を採用し、もう一方はキャンセルする。
  ///
  /// プロバイダーがキャンセルに応じない場合、その応答が返るまで戻らない。
  private func requestWithTimeout(
    _ request: RefinementRequest
  ) async -> Result<RefinementResponse, AIProviderError> {
    // Task のクロージャに typed throws を書くと壊れるため、エラーは値として受け取る（AIProvider の doc を参照）。
    await withTaskGroup(of: Result<RefinementResponse, AIProviderError>.self) { group in
      let provider = provider
      let timeout = timeout
      group.addTask {
        do throws(AIProviderError) {
          return .success(try await provider.refine(request))
        } catch {
          return .failure(error)
        }
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return .failure(.timeout)
      }
      let first = await group.next() ?? .failure(.timeout)
      group.cancelAll()
      return first
    }
  }
}

public enum RefinementRouterError: Error, Hashable, Sendable {
  case nonPositiveTimeout
}
