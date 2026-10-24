import Foundation
import UtterAI
import UtterPersistence

/// クラウド整形の前の予算上限の確認と、送信後の推定費用の記録（AI-04, AI-05）。
public protocol CloudRefinementBudgetSource: Sendable {
  /// 1回の整形の予算を用意する。予算上限を守れない（未設定・推定できない・使用量を読めない）なら理由を返し、
  /// 呼び出し側は送信しない。`.ready` を返したら、整形の後に `CloudRefinementBudget.finish()` を1回だけ呼ぶ
  ///
  /// - Parameters:
  ///   - model: 送信先のモデル名
  ///   - maxOutputTokens: 応答の最大トークン数（見込みの使用量に足す）
  ///   - request: 整形の入力。見込みの入力トークン数の推定に使う
  ///   - settings: 保存済みの最新の設定（月次予算・単価表）
  ///   - date: 実時刻。費用を計上する月を決める
  func begin(
    model: String, maxOutputTokens: Int, request: RefinementRequest, settings: AppSettings,
    at date: Date
  ) async -> CloudRefinementBudgetResult
}

/// 予算を用意した結果。
public enum CloudRefinementBudgetResult: Sendable {
  case ready(CloudRefinementBudget)
  case unavailable(CloudBudgetUnavailableReason)
}

/// 予算上限を確かめられず、送信しない理由（AI-04）。
public enum CloudBudgetUnavailableReason: Hashable, Sendable {
  /// 月次予算か単価表（通貨・更新日）が設定されていない
  case notConfigured
  /// 月次予算と単価表の通貨が一致しない
  case currencyMismatch
  /// 送信先のモデルが単価表にない
  case modelNotPriced
  /// 推定費用の累計を読み書きできない（保存先を開けない・保存に失敗した）
  case usageUnavailable
  /// 前の整形の推定費用の記録が終わっていない
  case previousRefinementInProgress
}

/// 1回の整形の予算。`RefinementRouter.refine` に渡し、整形の後に `finish()` で推定費用を記録する。
public struct CloudRefinementBudget: Sendable {
  public let budget: RefinementBudget
  private let onFinish: @Sendable () async -> Void

  public init(budget: RefinementBudget, onFinish: @escaping @Sendable () async -> Void) {
    self.budget = budget
    self.onFinish = onFinish
  }

  /// 整形の後（キャンセルされた場合も）に1回だけ呼ぶ。
  public func finish() async {
    await onFinish()
  }
}

/// 設定の月次予算・単価表と、`MonthlyUsageStore` に保存した今月の累計で予算を確かめる（AI-04, AI-05）。
///
/// - 整形ごとに `BudgetGuard` を作り、上限から今月の累計を引いた残りを上限にする。送信後に記録された推定費用を
///   `MonthlyUsageStore` に加算する
/// - 送信中にアプリが終了しても費用を少なく数えないよう、送信前に見込み費用を「未確定の予約」としてファイルに残し、
///   記録を終えたら消す。次の整形の前に予約が残っていれば、見込み費用で累計に加算してから判定する
/// - 月次予算・単価表（通貨・更新日・モデルの単価）が未設定、通貨が一致しない、累計を読み書きできないときは送信しない
/// - 前の整形の記録が終わる前に次の整形を始めたら、累計が古いため送信しない
/// - 累計の保存に一度でも失敗したら、累計が実際より少ない可能性があるため、以降は送信しない（安全側）。
///   予約のファイルが読めない場合は額がわからないため、ファイルを残し、起動し直しても送信しない
/// - データベースは最初に使うときに開く。読み書きはメインスレッドの外で行う
public actor UsageStoreBudgetSource: CloudRefinementBudgetSource {
  private let makeStore: @Sendable () throws -> MonthlyUsageStore
  private let pendingReservationURL: URL
  private let calendar: Calendar
  private var store: MonthlyUsageStore?
  /// 記録を待っている整形
  private var inFlight: UUID?
  private var hasPersistenceFailure = false

  /// - Parameters:
  ///   - makeStore: 使用量の保存先を開く
  ///   - pendingReservationURL: 未確定の予約を残すファイル。アプリ内（App Group ではない）に置く
  ///   - calendar: 費用を計上する月の判定に使う暦。既定はグレゴリオ暦・端末のタイムゾーン
  public init(
    makeStore: @escaping @Sendable () throws -> MonthlyUsageStore,
    pendingReservationURL: URL,
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) {
    self.makeStore = makeStore
    self.pendingReservationURL = pendingReservationURL
    self.calendar = calendar
  }

  /// 累計の保存に失敗して、クラウド整形を止めているか
  public var isDisabledByPersistenceFailure: Bool { hasPersistenceFailure }

  public func begin(
    model: String, maxOutputTokens: Int, request: RefinementRequest, settings: AppSettings,
    at date: Date
  ) async -> CloudRefinementBudgetResult {
    guard inFlight == nil else { return .unavailable(.previousRefinementInProgress) }
    guard !hasPersistenceFailure else { return .unavailable(.usageUnavailable) }
    guard let budgetSetting = settings.monthlyBudget,
      let priceTable = Self.priceTable(from: settings.priceTable),
      let currency = try? CostCurrency(code: budgetSetting.currencyCode),
      let (yearMonth, usageMonth) = months(of: date)
    else {
      return .unavailable(.notConfigured)
    }
    guard priceTable.currency == currency else { return .unavailable(.currencyMismatch) }
    let estimator = CostEstimator(priceTable: priceTable)
    let expectedUsage = Self.expectedUsage(for: request, maxOutputTokens: maxOutputTokens)
    guard let expectedCost = try? estimator.estimate(model: model, usage: expectedUsage) else {
      return .unavailable(.modelNotPriced)
    }
    guard let store = openStore(), recoverPendingReservation(into: store),
      let spent = try? store.spent(in: usageMonth, currencyCode: budgetSetting.currencyCode),
      // 残りを上限にする。使い切っていれば上限 0 になり、送信を許可しない
      let budget = try? MonthlyBudget(
        limitAmount: max(budgetSetting.limitAmount - spent, 0), currency: currency)
    else {
      return .unavailable(.usageUnavailable)
    }
    // 送信中に終了しても見込み費用を数えられるよう、送信前に予約を残す。残せなければ送信しない
    let pending = PendingReservation(
      year: usageMonth.year, month: usageMonth.month, currencyCode: budgetSetting.currencyCode,
      amount: expectedCost.amount)
    guard writePendingReservation(pending) else { return .unavailable(.usageUnavailable) }

    let guardian = BudgetGuard(
      budget: budget, estimator: estimator, ledger: MonthlyUsageLedger(currency: currency))
    let id = UUID()
    inFlight = id
    let currencyCode = budgetSetting.currencyCode
    return .ready(
      CloudRefinementBudget(
        budget: RefinementBudget(
          guard: guardian, model: model, expectedUsage: expectedUsage, month: yearMonth),
        onFinish: { [self] in
          let recorded = await guardian.ledger.spent(in: yearMonth)
          await self.finish(id, recorded: recorded, currencyCode: currencyCode, in: usageMonth)
        }))
  }

  /// 記録額を累計に加算し、未確定の予約を消す。同じ整形で2回目以降の呼び出しは何もしない
  private func finish(_ id: UUID, recorded: Decimal, currencyCode: String, in month: UsageMonth) {
    guard inFlight == id else { return }
    inFlight = nil
    if recorded > 0 {
      do {
        try openStore()?.record(recorded, currencyCode: currencyCode, in: month)
      } catch {
        // 予約を残し、次に起動したときに見込み費用で加算する
        hasPersistenceFailure = true
        return
      }
    }
    // 消せなければ次の整形の前に見込み費用でもう一度加算される（多めに数える側）
    try? FileManager.default.removeItem(at: pendingReservationURL)
  }

  /// 前回の未確定の予約が残っていれば、見込み費用で累計に加算して消す。失敗したら `false`
  private func recoverPendingReservation(into store: MonthlyUsageStore) -> Bool {
    guard FileManager.default.fileExists(atPath: pendingReservationURL.path) else { return true }
    guard let data = try? Data(contentsOf: pendingReservationURL),
      let pending = try? JSONDecoder().decode(PendingReservation.self, from: data),
      let month = try? UsageMonth(year: pending.year, month: pending.month)
    else {
      // 読めない予約は額がわからず、課金されたかもしれない費用を数えられない。消すと次の起動で忘れるため、
      // 残したまま送信しない（安全側。atomic に書くため通常は起きない）
      hasPersistenceFailure = true
      return false
    }
    do {
      try store.record(pending.amount, currencyCode: pending.currencyCode, in: month)
    } catch {
      hasPersistenceFailure = true
      return false
    }
    try? FileManager.default.removeItem(at: pendingReservationURL)
    return true
  }

  private func writePendingReservation(_ pending: PendingReservation) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: pendingReservationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(pending).write(to: pendingReservationURL, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private func openStore() -> MonthlyUsageStore? {
    if let store { return store }
    store = try? makeStore()
    return store
  }

  private func months(of date: Date) -> (YearMonth, UsageMonth)? {
    let components = calendar.dateComponents([.year, .month], from: date)
    guard let year = components.year, let month = components.month,
      let yearMonth = try? YearMonth(year: year, month: month),
      let usageMonth = try? UsageMonth(year: year, month: month)
    else {
      return nil
    }
    return (yearMonth, usageMonth)
  }

  /// 保存した単価表を UtterAI の単価表にする。通貨・更新日が未設定、または値が不正なら `nil`
  static func priceTable(from setting: PriceTableSetting) -> PriceTable? {
    guard let code = setting.currencyCode, let currency = try? CostCurrency(code: code),
      let day = setting.updatedOn,
      let updatedOn = try? CivilDate(year: day.year, month: day.month, day: day.day)
    else {
      return nil
    }
    var prices: [ModelPrice] = []
    for price in setting.prices {
      guard
        let converted = try? ModelPrice(
          model: price.model, inputPerMillionTokens: price.inputPerMillionTokens,
          outputPerMillionTokens: price.outputPerMillionTokens)
      else {
        return nil
      }
      prices.append(converted)
    }
    return try? PriceTable(currency: currency, updatedOn: updatedOn, prices: prices)
  }

  /// 送信前に予約する見込みの使用量。少なめに見積もらないよう、入力はプロンプトの UTF-8 のバイト数
  /// （1トークンは1バイト以上）に余裕を足し、出力は最大トークン数にする
  static func expectedUsage(for request: RefinementRequest, maxOutputTokens: Int) -> TokenUsage {
    let promptBytes =
      RefinementPromptBuilder().build(request).map { $0.system.utf8.count + $0.user.utf8.count }
      ?? request.text.utf8.count
    return TokenUsage(inputTokens: promptBytes + 64, outputTokens: maxOutputTokens)
  }
}

/// 送信前に残す未確定の予約。発話本文は持たない
struct PendingReservation: Codable, Hashable, Sendable {
  let year: Int
  let month: Int
  let currencyCode: String
  let amount: Decimal
}
