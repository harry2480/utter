import Foundation
import Observation
import UtterAI
import UtterPersistence

/// 設定画面の状態（2.1〜2.3節, 5章, 6章, AC-05, AI-05, CTX-01, CTX-02）。
///
/// 入力の検証は `SettingsForm`、保存は UtterPersistence の `AppSettingsStore`（版 2）、
/// 推定費用の表示用の値は `CloudCostBridge` が作る。ここは三者をつなぎ、保存できたときだけ画面の内容を進める。
/// 推定費用の累計はデータベースから読むため、メインスレッドの外で読む。
@MainActor
@Observable
final class SettingsModel {
  /// 推定費用の表示（AI-05）
  enum CostState: Equatable {
    case loading
    case summary(EstimatedCostSummary)
    /// 予算・単価表がそろわず、表示できない
    case unavailable(CloudCostBridge.Unavailable)
    /// 累計を読めない
    case unreadable
  }

  /// 編集中の値
  var form: SettingsForm
  /// 直前の保存で見つかった問題。保存に成功するか、元に戻すと空になる
  private(set) var issues: [SettingsIssue] = []
  /// 直前の保存に失敗した（書き込めなかった）か
  private(set) var saveFailed = false
  private(set) var cost: CostState = .loading

  private let store: AppSettingsStore
  private let openUsageStore: @Sendable () async throws -> MonthlyUsageStore
  /// 一度開いた保存先を使い回す（読み直すたびにデータベースを開き直さない）
  private var usageStore: MonthlyUsageStore?
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  /// 最後に読み込んだ・保存した設定。推定費用の表示はこの値（保存済みの値）で作る
  private var saved: AppSettings
  /// 推定費用の読み込みの世代。古い読み込みの結果で新しい表示を上書きしない
  private var costGeneration = 0

  init(
    store: AppSettingsStore,
    openUsageStore: @escaping @Sendable () async throws -> MonthlyUsageStore,
    now: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .current
  ) {
    self.store = store
    self.openUsageStore = openUsageStore
    self.now = now
    self.calendar = calendar
    let settings = store.load()
    saved = settings
    form = SettingsForm(settings: settings)
  }

  /// 保存済みの値を読み直す。画面を開くたびに呼び、ほかの画面（同意など）で変わった値も反映する
  func reload() {
    saved = store.load()
    form = SettingsForm(settings: saved)
    issues = []
    saveFailed = false
  }

  /// 編集中の値を捨て、保存済みの値に戻す
  func revert() {
    form = SettingsForm(settings: saved)
    issues = []
    saveFailed = false
  }

  /// 入力を検証して保存する。成功したら true。
  ///
  /// 保存の基準には保存先の最新の値を使い、この画面で扱わない項目（同意状態など）をほかの画面の変更ごと残す
  @discardableResult
  func save() -> Bool {
    let latest = store.load()
    let settings: AppSettings
    do throws(SettingsValidationError) {
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
    form = SettingsForm(settings: settings)
    issues = []
    saveFailed = false
    return true
  }

  /// 指定した行の問題
  func issues(forRow id: Int) -> [SettingsIssue] {
    issues.filter { $0.rowID == id }
  }

  /// 行に属さない問題のうち、`candidates` に含まれるもの
  func issues(in candidates: Set<SettingsIssue>) -> [SettingsIssue] {
    issues.filter { candidates.contains($0) }
  }

  /// 保存済みの設定で、今月の推定費用を読み直す（AI-05）
  func refreshCost() async {
    costGeneration += 1
    let generation = costGeneration
    let configuration: CloudCostBridge.Configuration
    do throws(CloudCostBridge.Unavailable) {
      configuration = try CloudCostBridge.configuration(for: saved, at: now(), in: calendar)
    } catch {
      cost = .unavailable(error)
      return
    }
    cost = .loading
    let openUsageStore = self.openUsageStore
    let usageStore = self.usageStore
    let result = await Task.detached {
      () -> (store: MonthlyUsageStore?, state: CostState) in
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
}
