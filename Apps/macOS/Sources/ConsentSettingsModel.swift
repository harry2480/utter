import Foundation
import Observation
import UtterCore
import UtterPersistence

/// 同意の画面の表示用の状態（AC-06）。判定と保存は `ConsentSettingsController` に任せる。
@MainActor
@Observable
final class ConsentSettingsModel {
  private(set) var screen: ConsentScreenState
  /// 保存に失敗したときの表示。失敗した操作は反映せず、保存済みの状態を表示し直す
  private(set) var saveFailed = false

  private let controller: ConsentSettingsController

  init(controller: ConsentSettingsController) {
    self.controller = controller
    self.screen = controller.load()
  }

  /// 画面を開くたびに、保存済みの最新の状態を読み直す
  func reload() {
    screen = controller.load()
    saveFailed = false
  }

  func setGranted(_ granted: Bool, for scope: ConsentScope) {
    do {
      screen = try controller.setGranted(granted, for: scope)
      saveFailed = false
    } catch {
      screen = controller.load()
      saveFailed = true
    }
  }
}
