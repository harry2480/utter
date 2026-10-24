import AppKit
import Observation
import UtterCore

/// 録音ショートカットをアプリに結線する（REC-01, REC-02）。
///
/// 押下・解放の解釈には `SessionCoordinator` の現在の状態を使い、セッション操作はそのまま `SessionCoordinator` へ渡す。
@MainActor
@Observable
final class ShortcutCoordinator {
  private(set) var status: GlobalShortcutStatus = .unassigned

  @ObservationIgnored private var controller: GlobalShortcutController?
  @ObservationIgnored private var resetObservers: [any NSObjectProtocol] = []

  /// - Parameters:
  ///   - currentPhase: セッションの現在の状態
  ///   - perform: 実行するセッション操作
  init(
    currentPhase: @escaping @MainActor () -> SessionPhase,
    perform: @escaping @MainActor (ShortcutCommand) -> Void
  ) {
    let controller = GlobalShortcutController(
      registrar: CarbonHotKeyRegistrar(),
      systemShortcuts: SystemShortcuts.loadEnabledBindings,
      currentPhase: currentPhase,
      perform: perform
    )
    self.controller = controller
    // スリープ中・ユーザー切替中に解放を取りこぼすと、Push-to-talk の押下中の状態が残るため破棄する
    let center = NSWorkspace.shared.notificationCenter
    resetObservers = [
      NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
    ].map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.controller?.reset() }
      }
    }
    status = controller.apply(Self.initialSetting())
  }

  isolated deinit {
    for observer in resetObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  var statusText: String {
    GlobalShortcutStatusText.text(for: status)
  }

  /// 起動時の割当。設定の保存（版2設定）が入るまでは割当なしで、何も登録しない。
  ///
  /// Debug ビルドに限り、実機確認のため起動引数で割り当てられる:
  /// `open utter.app --args -UtterDebugRecordShortcut ctrl+option+k -UtterDebugRecordShortcutMode ptt`
  private static func initialSetting() -> GlobalShortcutSetting? {
    #if DEBUG
      // 保存済みの設定（defaults write）は読まず、起動引数だけを見る
      let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      guard let text = arguments["UtterDebugRecordShortcut"] as? String,
        let combination = ShortcutNotation.parse(text)
      else { return nil }
      let mode: ShortcutTriggerMode =
        arguments["UtterDebugRecordShortcutMode"] as? String == "ptt" ? .pushToTalk : .toggle
      return GlobalShortcutSetting(combination: combination, mode: mode)
    #else
      return nil
    #endif
  }
}
