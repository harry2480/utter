import AppKit
import Observation
import UtterCore

/// 録音ショートカットをアプリに結線する（REC-01, REC-02）。
///
/// 録音（セッションの状態機械）はまだ結線していないため、セッション操作は最後の操作として表示するだけにする。
/// 現在の状態は「開始で録音中、停止・キャンセルで待機」とみなす仮のもので、録音を結線する PR で
/// `SessionStateMachine` の `phase` に置き換える。
@MainActor
@Observable
final class ShortcutCoordinator {
  private(set) var status: GlobalShortcutStatus = .unassigned
  private(set) var lastCommand: ShortcutCommand?

  @ObservationIgnored private var phase: SessionPhase = .idle
  @ObservationIgnored private var controller: GlobalShortcutController?
  @ObservationIgnored private var resetObservers: [any NSObjectProtocol] = []

  init() {
    let controller = GlobalShortcutController(
      registrar: CarbonHotKeyRegistrar(),
      systemShortcuts: SystemShortcuts.loadEnabledBindings,
      currentPhase: { [weak self] in self?.phase ?? .idle },
      perform: { [weak self] command in self?.handle(command) }
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

  private func handle(_ command: ShortcutCommand) {
    lastCommand = command
    switch command {
    case .startRecording: phase = .recording
    case .stopRecording, .cancelSession: phase = .idle
    }
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
