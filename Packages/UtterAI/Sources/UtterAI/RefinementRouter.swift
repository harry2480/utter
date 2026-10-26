import Synchronization
import UtterCore

/// 選択されたクラウドプロバイダーへ1回だけ送信し、応答を検証して返す（4.1節, AC-16）。
///
/// 同意がない・機密入力・失敗・上限時間の超過・検証失敗のときは、ローカル整形の結果に退避して発話を失わない。
/// 失敗しても再送や別のクラウドプロバイダーへの切り替えはしない（AI-04）。
/// 別のクラウドプロバイダーへの切り替えは、明示的な許可がある場合に `CloudFallbackRouter` が行う。
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
  /// - Parameters:
  ///   - consent: 最新の同意状態を返す。プロバイダーの送信先への整形の同意がなければ、プロバイダーを呼ばない（AC-06）。
  ///     別の送信先・別の送信内容（音声・Edit の選択テキスト）への同意では送信しない。予約の前と、予約を待った後のプロバイダーを呼ぶ直前に呼ぶ。
  ///     予約を待つ間に撤回された場合は、送信せずに予約を取り消す。
  ///     同期的に呼ぶため、メインスレッドを待たずに返す（最新の同意状態を保持しておき、それを返すなど）
  ///   - budget: 予算上限の設定（AI-04, AI-05）。送信前に見込み費用を予約し、上限を超えるなら
  ///     プロバイダーを呼ばずに `.providerFailed(.budgetExceeded)` で退避する。送信後は使用量で確定する。
  ///     予算上限を守る送信先（Claude など、トークン課金の API）では必ず渡す。予算の確認を省略できないよう既定値は持たせず、
  ///     `nil` はトークン課金ではない送信先（Sign in with ChatGPT など）に限って明示的に渡す。
  ///     送信先（`provider.destination`）では課金方式を区別できない。同じ `.chatGPT` でも OpenAI API キー方式（`OpenAIProvider`）は
  ///     トークン課金のため必ず渡す
  ///   - sensitivity: その時点の入力先で判定し直した結果（7章, AC-12）。`allowsCloudTransmission` でなければ
  ///     プロバイダーを呼ばずに `.sensitiveInputSuppressed` で退避する。予約の前と、予約を待った後のプロバイダーを呼ぶ直前に呼ぶ。
  ///     予約を待つ間に機密入力へ変わった場合は、送信せずに予約を取り消す。確認を省略できないよう既定値は持たせない。
  ///     同期的に呼ぶため、メインスレッドを待たずに返す（入力先の最新の判定を保持しておき、それを返すなど）
  /// - Returns: 整形結果。予算の台帳に記録した推定費用は `recordedCost` に入る（AI-05）
  /// - Throws: 呼び出し元の Task がキャンセルされた場合。キャンセルされたセッションの結果は使わないため退避しない。
  ///   送信後にキャンセルされた場合も推定費用は台帳に記録し、`BudgetGuard` の `onRecord` に渡す
  public func refine(
    _ request: RefinementRequest,
    consent: @Sendable () -> ConsentState,
    budget: RefinementBudget?,
    sensitivity: @Sendable () -> SensitiveInputDecision
  ) async throws(CancellationError) -> RefinementOutcome {
    if Task.isCancelled {
      throw CancellationError()
    }
    if request.mode == .raw {
      return RefinementOutcome(text: request.text, source: .raw)
    }
    guard consent().allows(.textRefinement(provider.destination)) else {
      return fallback(request, reason: .consentNotGranted)
    }
    // 機密入力なら予約もしない
    guard sensitivity().allowsCloudTransmission else {
      return fallback(request, reason: .sensitiveInputSuppressed)
    }

    let reservation: BudgetReservation?
    switch try await Self.reserve(budget) {
    case .success(let reserved):
      reservation = reserved
    case .failure(let error):
      return fallback(request, reason: .providerFailed(error))
    }
    // 予約を待つ間に同意が撤回されたか、入力先が機密入力へ変わったら、送信せずに予約を取り消す
    if let budget, let reservation {
      var reason: RefinementFallbackReason?
      if !consent().allows(.textRefinement(provider.destination)) {
        reason = .consentNotGranted
      } else if !sensitivity().allowsCloudTransmission {
        reason = .sensitiveInputSuppressed
      }
      if let reason {
        await budget.guard.cancel(reservation)
        // 取り消しを待つ間にキャンセルされたら、退避の結果を返さない
        if Task.isCancelled {
          throw CancellationError()
        }
        return fallback(request, reason: reason)
      }
    }

    let provider = provider
    let result = await Self.requestWithTimeout(timeout) { () async -> RefinementResult in
      do throws(AIProviderError) {
        return .success(try await provider.refine(request))
      } catch {
        return .failure(error)
      }
    }
    var recordedCost: RecordedEstimatedCost?
    if let budget, let reservation {
      recordedCost = await budget.guard.resolve(reservation, with: result.map(\.usage))
    }
    if Task.isCancelled {
      throw CancellationError()
    }

    switch result {
    case .success(let response):
      if let failure = validator.validate(response.text, for: request) {
        return fallback(
          request, reason: .validationFailed(failure), usage: response.usage,
          recordedCost: recordedCost)
      }
      // 末尾の改行がコマンドの実行にならないよう、前後の空白・改行を除いて挿入する。
      return RefinementOutcome(
        text: Self.trimmingWhitespace(response.text), source: .cloud, usage: response.usage,
        recordedCost: recordedCost)
    case .failure(let error):
      return fallback(request, reason: .providerFailed(error), recordedCost: recordedCost)
    }
  }

  /// 予算があれば送信前に見込み費用を予約する（AI-04, AI-05）。`EditRouter` と共用する。
  ///
  /// 予算がなければ `nil` を、上限を超えるなら `.budgetExceeded` を返す。
  /// 予約を待つ間にキャンセルされたら、予約を取り消して `CancellationError` を投げる（予算超過でも退避の結果を返さない）。
  static func reserve(
    _ budget: RefinementBudget?
  ) async throws(CancellationError) -> Result<BudgetReservation?, AIProviderError> {
    if Task.isCancelled {
      throw CancellationError()
    }
    guard let budget else {
      return .success(nil)
    }
    let reservation: BudgetReservation
    do throws(AIProviderError) {
      reservation = try await budget.guard.reserve(
        model: budget.model, expectedUsage: budget.expectedUsage, in: budget.month)
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      return .failure(error)
    }
    // 予約を待つ間にキャンセルされたら、送信せずに予約を取り消す
    if Task.isCancelled {
      await budget.guard.cancel(reservation)
      throw CancellationError()
    }
    return .success(reservation)
  }

  private func fallback(
    _ request: RefinementRequest,
    reason: RefinementFallbackReason,
    usage: TokenUsage? = nil,
    recordedCost: RecordedEstimatedCost? = nil
  ) -> RefinementOutcome {
    RefinementOutcome(
      text: localRefiner.refine(request), source: .localFallback(reason), usage: usage,
      recordedCost: recordedCost)
  }

  static func trimmingWhitespace(_ text: String) -> String {
    String(text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
  }

  /// プロバイダーの応答と上限時間を競わせ、先に決まった方を返す。`EditRouter` と共用する。
  ///
  /// 上限時間を過ぎたら、プロバイダーがキャンセルに応じなくても待たずに戻る。
  /// 呼び出し元がキャンセルされた場合は `.cancelled` を返す。
  ///
  /// - Parameter operation: プロバイダーを呼ぶ処理。Task のクロージャに typed throws を書くと壊れるため
  ///   （AIProvider の doc を参照）、エラーは値として返す
  static func requestWithTimeout(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async -> RefinementResult
  ) async -> RefinementResult {
    let race = Race<RefinementResponse>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        race.install(continuation)
        race.add(Task { race.finish(await operation()) })
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

/// プロバイダー1回分の結果
typealias RefinementResult = Result<RefinementResponse, AIProviderError>

/// 最初に届いた結果で1回だけ continuation を再開し、残りの Task をキャンセルする。
/// 整形（`RefinementRouter` / `EditRouter`）とクラウド STT（`OpenAISpeechRecognizer`）の上限時間で使う。
final class Race<Success: Sendable>: Sendable {
  typealias Outcome = Result<Success, AIProviderError>

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

/// クラウド整形の前に予算上限を確認するための設定（AI-04, AI-05）。
public struct RefinementBudget: Sendable {
  public let `guard`: BudgetGuard
  /// 送信先のモデル名。単価表の照合に使う
  public let model: String
  /// 送信前に予約する見込みのトークン使用量。応答の使用量がわからない場合はこの量で記録するため、
  /// 少なめに記録しないよう、入力の見込みに出力の上限（max_tokens）を足した量にする
  public let expectedUsage: TokenUsage
  /// 費用を計上する月
  public let month: YearMonth

  public init(guard: BudgetGuard, model: String, expectedUsage: TokenUsage, month: YearMonth) {
    self.guard = `guard`
    self.model = model
    self.expectedUsage = expectedUsage
    self.month = month
  }
}

public enum RefinementRouterError: Error, Hashable, Sendable {
  case nonPositiveTimeout
}
