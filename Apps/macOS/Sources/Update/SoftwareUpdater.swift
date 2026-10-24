import Foundation
import OSLog
import Observation
import Sparkle
import UtterCore

/// 自動更新（Sparkle 2）のアダプター。
///
/// Phase 0 #47（依存のライセンス確定）の判定待ちの先行実装で、既定で無効。
/// Info.plist の appcast URL と EdDSA 公開鍵から `SoftwareUpdateConfiguration` を作れたときだけ
/// Sparkle を起動する。作れなければ Sparkle のオブジェクトを作らず、更新の確認で通信しない。
/// 確認の間隔・システムプロファイルを送らないこと・自動インストールを選べないことは Apps/macOS/Info.plist で決める。
@MainActor
@Observable
final class SoftwareUpdater {
  /// Sparkle が起動しているか（設定がそろっているか）。false ならメニューに更新の項目を出さない。
  var isAvailable: Bool { controller != nil }
  /// 今「アップデートを確認」できるか（確認中は false）。Sparkle の値を KVO で写す。
  private(set) var canCheckForUpdates = false
  /// 定期的に自動で確認するか。Sparkle の値を KVO で写す
  /// （初回の問い合わせへの回答など、Sparkle 側で変わった値もメニューに反映する）。
  private(set) var automaticallyChecksForUpdates = false

  @ObservationIgnored private let controller: SPUStandardUpdaterController?
  @ObservationIgnored private let delegate = NoSystemProfileDelegate()
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []
  @ObservationIgnored private let logger = Logger(subsystem: "utter.mac", category: "update")

  init(infoDictionary: [String: Any]) {
    do {
      _ = try SoftwareUpdateConfiguration(infoDictionary: infoDictionary)
    } catch .notConfigured {
      controller = nil
      return
    } catch {
      // 片方だけの設定などの誤り。値（URL・鍵）はログに出さず、理由だけ残す
      controller = nil
      logger.error("自動更新の設定に誤りがあるため無効にします: \(String(describing: error), privacy: .public)")
      return
    }

    let controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
    // Info.plist で無効にしているが、利用者の defaults で上書きされても送らない
    controller.updater.sendsSystemProfile = false
    self.controller = controller

    let updater = controller.updater
    observations = [
      updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
        let value = updater.canCheckForUpdates
        Task { @MainActor in self?.canCheckForUpdates = value }
      },
      updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) {
        [weak self] updater, _ in
        let value = updater.automaticallyChecksForUpdates
        Task { @MainActor in self?.automaticallyChecksForUpdates = value }
      },
    ]
  }

  /// 自動確認の有無を切り替える。Sparkle が defaults に保存し、KVO でこの型の値も更新される。
  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    controller?.updater.automaticallyChecksForUpdates = enabled
  }

  /// 利用者の操作で今すぐ確認する。
  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }
}

/// appcast の取得に OS 版・機種などの情報を付けない（テレメトリを実装しない）。
private final class NoSystemProfileDelegate: NSObject, SPUUpdaterDelegate {
  func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
    []
  }

  func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool)
    -> [[String: String]]
  {
    []
  }
}
