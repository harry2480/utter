import Foundation
import Synchronization
import Testing
import UtterAI
import UtterCore
import UtterPersistence

@testable import UtteriOSKit

/// テストごとの `UserDefaults`（suite）。終わったら消す
final class TemporaryDefaults {
  let suiteName: String
  let defaults: UserDefaults

  init(_ name: String = UUID().uuidString) throws {
    suiteName = "utter.tests.UtteriOSKit.\(name)"
    defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

enum CloudFixtures {
  static let claudeConsent = ConsentScope.transmission(.textRefinement(.claude))

  // swift-format-ignore: NeverUseForceTry
  static let usd = try! CostCurrency(code: "USD")

  /// 既定のモデルの単価を載せた単価表
  // swift-format-ignore: NeverUseForceTry
  static let priceTable = try! PriceTable(
    currency: usd, updatedOn: CivilDate(year: 2026, month: 10, day: 1),
    prices: [
      ModelPrice(
        model: AppSettings.defaultRefinementModel, inputPerMillionTokens: 3,
        outputPerMillionTokens: 15)
    ])

  /// 上限に十分な余裕がある予算
  static func generousBudget(month: YearMonth) throws -> RefinementBudget {
    RefinementBudget(
      guard: BudgetGuard(
        budget: try MonthlyBudget(limitAmount: 100, currency: usd),
        estimator: CostEstimator(priceTable: priceTable), ledger: MonthlyUsageLedger(currency: usd)),
      model: AppSettings.defaultRefinementModel,
      expectedUsage: TokenUsage(inputTokens: 1000, outputTokens: 1000), month: month)
  }
}

/// テスト用の予算。`budget` が `nil` なら予算を確かめられない（未設定）として返す。呼び出しを記録する
actor StubBudgetSource: CloudRefinementBudgetSource {
  private let budget: RefinementBudget?
  /// `begin` の中で呼ぶ（予算の確認を待つ間の操作を再現する）
  private let onBegin: @Sendable () async -> Void
  private(set) var beginCount = 0
  private(set) var finishCount = 0

  init(budget: RefinementBudget?, onBegin: @escaping @Sendable () async -> Void = {}) {
    self.budget = budget
    self.onBegin = onBegin
  }

  func begin(
    model: String, maxOutputTokens: Int, request: RefinementRequest, settings: AppSettings,
    at date: Date
  ) async -> CloudRefinementBudgetResult {
    beginCount += 1
    await onBegin()
    guard let budget else { return .unavailable(.notConfigured) }
    return .ready(CloudRefinementBudget(budget: budget) { [self] in await self.finished() })
  }

  private func finished() {
    finishCount += 1
  }
}
