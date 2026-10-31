import Foundation
import Observation
import UtterAI
import UtterPersistence

/// iOS の整形・予算の設定画面の状態（2.3節, AI-03, AI-04, AI-05, iOS-10）。
///
/// 入力の検証は `RefinementSettingsForm`、保存は UtterPersistence の `AppSettingsStore`（版 2）が持つ。
/// クラウド整形（`CloudRefinement`）と同じ `AppSettingsStore` を渡すと、保存した時点で次の整形から反映される。
/// この画面は設定値を書くだけで、クラウドへは送信しない（送信の可否は `CloudRefinement` が同意から判定する, AC-06）。
///
/// 今月の推定費用は、予算の判定（`UsageStoreBudgetSource`）と同じく、保存した予算の通貨の今月の累計から作る。
/// 累計はデータベースから読むため、メインスレッドの外で読む。
@MainActor
@Observable
public final class RefinementSettingsModel {
  /// 推定費用の表示（AI-05）
  public enum CostState: Hashable, Sendable {
    case loading
    case summary(EstimatedCostSummary)
    /// 予算・単価表がそろわず、表示できない
    case unavailable(CostUnavailableReason)
    /// 累計を読めない
    case unreadable
  }

  /// 推定費用を表示できない理由
  public enum CostUnavailableReason: Error, Hashable, Sendable {
    /// 月次予算が未設定
    case budgetNotSet
    /// 単価表の通貨か更新日が未設定
    case priceTableIncomplete
    /// 予算と単価表の通貨が異なる（為替換算はしない）
    case currencyMismatch
    /// 年月を集計に使える範囲で表せない
    case invalidMonth
  }

  /// 編集中の値
  public var form: RefinementSettingsForm
  /// 直前の保存で見つかった問題。保存に成功するか、元に戻すと空になる
  public private(set) var issues: [RefinementSettingsIssue] = []
  /// 直前の保存に失敗した（書き込めなかった）か
  public private(set) var saveFailed = false
  public private(set) var cost: CostState = .loading

  @ObservationIgnored private let store: AppSettingsStore
  @ObservationIgnored private let openUsageStore: @Sendable () throws -> MonthlyUsageStore
  /// 一度開いた保存先を使い回す（読み直すたびにデータベースを開き直さない）
  @ObservationIgnored private var usageStore: MonthlyUsageStore?
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private let calendar: Calendar
  /// 最後に読み込んだ・保存した設定。推定費用の表示はこの値（保存済みの値）で作る
  @ObservationIgnored private var saved: AppSettings
  /// 推定費用の読み込みの世代。古い読み込みの結果で新しい表示を上書きしない
  @ObservationIgnored private var costGeneration = 0

  /// - Parameters:
  ///   - store: 設定の保存先。クラウド整形・同意の画面と同じものを渡す
  ///   - openUsageStore: 推定費用の累計の保存先を開く。最初に推定費用を読むときに、メインスレッドの外で呼ぶ
  ///   - now: 実時刻（推定費用を表示する月の判定）
  ///   - calendar: 月の判定に使う暦。予算の判定（`UsageStoreBudgetSource`）と同じものを渡す
  public init(
    store: AppSettingsStore,
    openUsageStore: @escaping @Sendable () throws -> MonthlyUsageStore,
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) {
    self.store = store
    self.openUsageStore = openUsageStore
    self.now = now
    self.calendar = calendar
    let settings = store.load()
    saved = settings
    form = RefinementSettingsForm(settings: settings)
  }

  /// 保存済みの値を読み直す。画面を開くたびに呼び、ほかの画面（同意など）で変わった値も反映する
  public func reload() {
    saved = store.load()
    form = RefinementSettingsForm(settings: saved)
    issues = []
    saveFailed = false
  }

  /// 編集中の値を捨て、保存済みの値に戻す
  public func revert() {
    form = RefinementSettingsForm(settings: saved)
    issues = []
    saveFailed = false
  }

  /// 入力を検証して保存する。成功したら true。
  ///
  /// 保存の基準には保存先の最新の値を使い、この画面で扱わない項目（同意状態など）をほかの画面の変更ごと残す
  @discardableResult
  public func save() -> Bool {
    let latest = store.load()
    let settings: AppSettings
    do throws(RefinementSettingsValidationError) {
      settings = try form.applied(to: latest)
    } catch {
      issues = error.issues
      saveFailed = false
      return false
    }
    do {
      try store.save(settings)
    } catch {
      issues = []
      saveFailed = true
      return false
    }
    saved = settings
    form = RefinementSettingsForm(settings: settings)
    issues = []
    saveFailed = false
    return true
  }

  /// 指定した行の問題
  public func issues(forRow id: Int) -> [RefinementSettingsIssue] {
    issues.filter { $0.rowID == id }
  }

  /// 行に属さない問題のうち、`candidates` に含まれるもの
  public func issues(in candidates: Set<RefinementSettingsIssue>) -> [RefinementSettingsIssue] {
    issues.filter { candidates.contains($0) }
  }

  /// 通貨・単価表・今月の推定費用を出すか。これらは月次予算を使うときだけ要る（予算なしでは上限なしで送り、推定費用を記録しない, AI-04）。
  /// 予算をオフにしても入力済みの値は消さない。保存で通貨・単価表に問題が見つかったときは、直せるよう隠さない
  public var showsBudgetDetails: Bool {
    form.budgetEnabled
      || issues.contains { $0 == .currencyCode || $0 == .priceUpdatedOnMissing || $0.rowID != nil }
  }

  /// 保存済みの設定で、今月の推定費用を読み直す（AI-05）
  public func refreshCost() async {
    costGeneration += 1
    let generation = costGeneration
    let configuration: CostConfiguration
    switch Self.costConfiguration(for: saved, at: now(), in: calendar) {
    case .success(let value):
      configuration = value
    case .failure(let reason):
      cost = .unavailable(reason)
      return
    }
    cost = .loading
    let openUsageStore = self.openUsageStore
    let usageStore = self.usageStore
    let result = await Task.detached {
      () -> (store: MonthlyUsageStore?, state: CostState) in
      let opened: MonthlyUsageStore
      do {
        opened = try usageStore ?? openUsageStore()
      } catch {
        return (nil, .unreadable)
      }
      return (
        opened,
        RefinementSettingsModel.costState(configuration: configuration, usageStore: opened)
      )
    }.value
    if let store = result.store {
      self.usageStore = store
    }
    guard generation == costGeneration else { return }
    cost = result.state
  }

  // MARK: - 推定費用の計算

  /// 予算・単価表・集計月をそろえた値
  struct CostConfiguration: Sendable {
    let budget: MonthlyBudget
    let priceTable: PriceTable
    let month: YearMonth
    let usageMonth: UsageMonth
  }

  /// 設定と現在時刻から、今月の推定費用の計算に使う値を作る。0 円や仮の値で補わない
  nonisolated static func costConfiguration(
    for settings: AppSettings, at date: Date, in calendar: Calendar
  ) -> Result<CostConfiguration, CostUnavailableReason> {
    guard let budgetSetting = settings.monthlyBudget,
      let currency = try? CostCurrency(code: budgetSetting.currencyCode),
      let budget = try? MonthlyBudget(limitAmount: budgetSetting.limitAmount, currency: currency)
    else {
      return .failure(.budgetNotSet)
    }
    // 予算の判定と同じ変換を使う
    guard let priceTable = UsageStoreBudgetSource.priceTable(from: settings.priceTable) else {
      return .failure(.priceTableIncomplete)
    }
    guard priceTable.currency == currency else { return .failure(.currencyMismatch) }
    let components = calendar.dateComponents([.year, .month], from: date)
    guard let year = components.year, let monthNumber = components.month,
      let month = try? YearMonth(year: year, month: monthNumber),
      let usageMonth = try? UsageMonth(year: year, month: monthNumber)
    else {
      return .failure(.invalidMonth)
    }
    return .success(
      CostConfiguration(
        budget: budget, priceTable: priceTable, month: month, usageMonth: usageMonth))
  }

  /// 保存済みの累計から今月の推定費用を作る。データベースを読むため、メインスレッドの外で呼ぶ
  nonisolated static func costState(
    configuration: CostConfiguration, usageStore: MonthlyUsageStore
  ) -> CostState {
    let currency = configuration.budget.currency
    guard
      let spent = try? usageStore.spent(
        in: configuration.usageMonth, currencyCode: currency.code),
      let ledger = try? MonthlyUsageLedger(
        currency: currency, spentByMonth: [configuration.month: spent]),
      let summary = try? EstimatedCostSummary(
        month: configuration.month, budget: configuration.budget, ledger: ledger,
        priceTable: configuration.priceTable)
    else {
      return .unreadable
    }
    return .summary(summary)
  }
}
