import Synchronization

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
  /// - Raw モードは整形しないため、送信せずに STT テキストをそのまま返す
  /// - 呼び出し元はキャンセルしていないのにプロバイダーが `.cancelled` を返した場合は、
  ///   発話を失わないよう他の失敗と同じく退避する
  ///
  /// - Parameter cloudConsentGranted: クラウド整形への送信の同意。`false` ならプロバイダーを呼ばない（AC-06）
  /// - Throws: 呼び出し元の Task がキャンセルされた場合。キャンセルされたセッションの結果は使わないため退避しない
  public func refine(
    _ request: RefinementRequest,
    cloudConsentGranted: Bool
  ) async throws(CancellationError) -> RefinementOutcome {
    if Task.isCancelled {
      throw CancellationError()
    }
    if request.mode == .raw {
      return RefinementOutcome(text: request.text, source: .raw)
    }
    guard cloudConsentGranted else {
      return fallback(request, reason: .consentNotGranted)
    }

    let result = await requestWithTimeout(request)
    if Task.isCancelled {
      throw CancellationError()
    }

    switch result {
    case .success(let response):
      if let failure = validator.validate(response.text, for: request) {
        return fallback(request, reason: .validationFailed(failure), usage: response.usage)
      }
      // 末尾の改行がコマンドの実行にならないよう、前後の空白・改行を除いて挿入する。
      return RefinementOutcome(
        text: Self.trimmingWhitespace(response.text), source: .cloud, usage: response.usage)
    case .failure(let error):
      return fallback(request, reason: .providerFailed(error))
    }
  }

  private func fallback(
    _ request: RefinementRequest,
    reason: RefinementFallbackReason,
    usage: TokenUsage? = nil
  ) -> RefinementOutcome {
    RefinementOutcome(
      text: localRefiner.refine(request), source: .localFallback(reason), usage: usage)
  }

  private static func trimmingWhitespace(_ text: String) -> String {
    String(text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
  }

  /// プロバイダーの応答と上限時間を競わせ、先に決まった方を返す。
  ///
  /// 上限時間を過ぎたら、プロバイダーがキャンセルに応じなくても待たずに戻る。
  /// 呼び出し元がキャンセルされた場合は `.cancelled` を返す。
  private func requestWithTimeout(
    _ request: RefinementRequest
  ) async -> Result<RefinementResponse, AIProviderError> {
    let race = Race()
    let provider = provider
    let timeout = timeout
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        race.install(continuation)
        // Task のクロージャに typed throws を書くと壊れるため、エラーは値として受け取る（AIProvider の doc を参照）。
        race.add(
          Task {
            do throws(AIProviderError) {
              race.finish(.success(try await provider.refine(request)))
            } catch {
              race.finish(.failure(error))
            }
          })
        race.add(
          Task {
            try? await Task.sleep(for: timeout)
            race.finish(.failure(.timeout))
          })
      }
    } onCancel: {
      race.finish(.failure(.cancelled))
    }
  }
}

/// 最初に届いた結果で1回だけ continuation を再開し、残りの Task をキャンセルする。
private final class Race: Sendable {
  typealias Outcome = Result<RefinementResponse, AIProviderError>

  private struct State {
    var continuation: CheckedContinuation<Outcome, Never>?
    var result: Outcome?
    var tasks: [Task<Void, Never>] = []
  }

  private let state = Mutex(State())

  func install(_ continuation: CheckedContinuation<Outcome, Never>) {
    let result = state.withLock { state -> Outcome? in
      guard let result = state.result else {
        state.continuation = continuation
        return nil
      }
      return result
    }
    if let result {
      continuation.resume(returning: result)
    }
  }

  func add(_ task: Task<Void, Never>) {
    let isFinished = state.withLock { state in
      if state.result == nil {
        state.tasks.append(task)
      }
      return state.result != nil
    }
    if isFinished {
      task.cancel()
    }
  }

  func finish(_ result: Outcome) {
    let resolved = state.withLock {
      state -> (CheckedContinuation<Outcome, Never>?, [Task<Void, Never>])? in
      guard state.result == nil else {
        return nil
      }
      state.result = result
      defer {
        state.continuation = nil
        state.tasks = []
      }
      return (state.continuation, state.tasks)
    }
    guard let (continuation, tasks) = resolved else {
      return
    }
    continuation?.resume(returning: result)
    for task in tasks {
      task.cancel()
    }
  }
}

public enum RefinementRouterError: Error, Hashable, Sendable {
  case nonPositiveTimeout
}
