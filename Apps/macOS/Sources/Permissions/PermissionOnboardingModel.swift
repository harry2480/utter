import Observation
import UtterCore

/// 権限オンボーディングの画面の状態を持つ（PERM-01, PERM-02）。判定は UtterCore の `PermissionOnboarding` が行う。
///
/// 権限の状態は画面を開いたとき・アプリが前面に来たとき・要求の後に取り直す（`refresh()`）。
/// 要求は `perform(_:)`（画面のボタン）からだけ行う。
@MainActor
@Observable
final class PermissionOnboardingModel {
  private(set) var onboarding: PermissionOnboarding
  /// 要求の途中。連打で要求を重ねないため、その間はボタンを無効にする
  private(set) var isPerforming = false
  private let configuration: MacPermissionConfiguration
  private let access: any PermissionAccess
  private let defaults: PermissionDefaults

  init(
    configuration: MacPermissionConfiguration, access: any PermissionAccess,
    defaults: PermissionDefaults
  ) {
    self.configuration = configuration
    self.access = access
    self.defaults = defaults
    onboarding = PermissionOnboarding(
      features: configuration.features, permissions: PermissionSnapshot(),
      requirements: configuration.requirements)
  }

  /// 権限の状態を取り直す。これまでに許可を観測した権限と比べて取り消しを示し、今回の観測を覚える（PERM-02）
  func refresh() {
    let snapshot = access.currentSnapshot()
    var history = defaults.history
    onboarding = PermissionOnboarding(
      features: configuration.features, permissions: snapshot,
      requirements: configuration.requirements, previous: history.previousSnapshot)
    history.record(snapshot)
    defaults.history = history
  }

  /// 段階の操作（要求・システム設定を開く）。利用者のボタン操作から呼ぶ
  func perform(_ step: PermissionOnboardingStep) async {
    guard !isPerforming, case .needed(let action, _) = step.state else { return }
    isPerforming = true
    defer { isPerforming = false }
    switch action {
    case .requestFromSystem:
      await access.request(step.permission)
    case .openSystemSettings:
      access.openSystemSettings(for: step.permission)
    case .notChangeableByUser:
      return
    }
    refresh()
  }
}
