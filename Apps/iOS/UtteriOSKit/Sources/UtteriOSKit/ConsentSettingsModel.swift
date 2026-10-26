import Foundation
import Observation
import UtterCore
import UtterPersistence

/// iOS の同意の画面の表示用の状態（iOS-10, AC-06）。判定と保存は `ConsentSettingsController` に任せる。
///
/// macOS の画面（Apps/macOS の `ConsentSettingsModel`）と同じ振る舞いにする。クラウド整形（`CloudRefinement`）と
/// 同じ `AppSettingsStore` を渡すと、撤回は保存した時点で次の送信から反映される。
@MainActor
@Observable
public final class ConsentSettingsModel {
  public private(set) var screen: ConsentScreenState
  /// 保存に失敗したときの表示。失敗した操作は反映せず、保存済みの状態を表示し直す
  public private(set) var saveFailed = false

  @ObservationIgnored private let controller: ConsentSettingsController

  public init(controller: ConsentSettingsController) {
    self.controller = controller
    self.screen = controller.load()
  }

  /// 画面を開くたびに、保存済みの最新の状態を読み直す
  public func reload() {
    screen = controller.load()
    saveFailed = false
  }

  public func setGranted(_ granted: Bool, for scope: ConsentScope) {
    do {
      screen = try controller.setGranted(granted, for: scope)
      saveFailed = false
    } catch {
      screen = controller.load()
      saveFailed = true
    }
  }
}
