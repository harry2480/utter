import AppKit
import Observation
import UtterCore

/// 録音ショートカットをアプリに結線する（REC-01, REC-02）。
///
/// 録音（セッションの状態機械）はまだ結線していないため、セッション操作は最後の操作として表示するだけにする。
/// 現在の状態は「開始で録音中、停止・キャンセルで待機」とみなす仮のもので、録音を結線する PR で
/// `SessionStateMachine` の `phase` に置き換える。そのとき、ショートカット以外の要因で状態が変わったら
/// `GlobalShortcutController.sessionPhaseDidChange()` を呼ぶ（Esc の捕捉をセッション中だけ有効にするため）。
///
/// 修飾キー単独と Esc 捕捉（#51 の判定待ち）は既定で無効（`ShortcutCapabilities.keyCombinationsOnly`）。
@MainActor
@Observable
final class ShortcutCoordinator {
  private(set) var status: GlobalShortcutStatus = .unassigned
  private(set) var escapeStatus: EscapeCaptureStatus = .off
  private(set) var lastCommand: ShortcutCommand?

  @ObservationIgnored private var phase: SessionPhase = .idle
  @ObservationIgnored private var controller: GlobalShortcutController?
  @ObservationIgnored private var resetObservers: [any NSObjectProtocol] = []
  @ObservationIgnored private var permissionTimer: Timer?

  /// 権限の取り消し・許可を確かめる間隔（仮置き。権限の変化を検出する OS の通知がないため定期的に確かめる。
  /// CGPreflightListenEventAccess・AXIsProcessTrusted は軽い呼び出しで、イベントタップを使う機能が有効なときだけ動かす）
  private static let permissionCheckInterval: TimeInterval = 5

  init() {
    let controller = GlobalShortcutController(
      registrar: CarbonHotKeyRegistrar(),
      tapFactory: CGKeyEventTapFactory(),
      permissions: SystemEventTapPermissions(),
      capabilities: Self.capabilities(),
      systemShortcuts: SystemShortcuts.loadEnabledBindings,
      currentPhase: { [weak self] in self?.phase ?? .idle },
      perform: { [weak self] command in self?.handle(command) }
    )
    self.controller = controller
    controller.onStatusChange = { [weak self] in self?.syncStatus() }
    // スリープ中・ユーザー切替中に解放を取りこぼすと、Push-to-talk の押下中の状態が残るため破棄する
    let center = NSWorkspace.shared.notificationCenter
    resetObservers = [
      NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
    ].map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.controller?.reset() }
      }
    }
    controller.apply(Self.initialSetting())
    syncStatus()
    // イベントタップを使わないなら権限を確かめない（PERM-01）
    if controller.usesEventTaps {
      permissionTimer = Timer.scheduledTimer(
        withTimeInterval: Self.permissionCheckInterval, repeats: true
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.controller?.refreshPermissions() }
      }
    }
  }

  isolated deinit {
    for observer in resetObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    permissionTimer?.invalidate()
  }

  var statusText: String {
    GlobalShortcutStatusText.text(for: status)
  }

  var escapeStatusText: String? {
    GlobalShortcutStatusText.text(for: escapeStatus)
  }

  /// 不足していて、メニューから求められる権限
  var missingPermissions: [EventTapPermission] {
    var result: [EventTapPermission] = []
    if case .unavailable(_, .eventTapUnavailable(.permissionMissing(let permission))) = status {
      result.append(permission)
    }
    if case .unavailable(.permissionMissing(let permission)) = escapeStatus,
      !result.contains(permission)
    {
      result.append(permission)
    }
    return result
  }

  /// 利用者がメニューで選んだときだけ権限を求める（PERM-01）。許可は定期的な確認で反映する
  func requestPermission(_ permission: EventTapPermission) {
    controller?.requestPermission(permission)
  }

  private func syncStatus() {
    guard let controller else { return }
    status = controller.status
    escapeStatus = controller.escapeStatus
  }

  private func handle(_ command: ShortcutCommand) {
    lastCommand = command
    switch command {
    case .startRecording: phase = .recording
    case .stopRecording, .cancelSession: phase = .idle
    }
  }

  /// 修飾キー単独・Esc 捕捉を使うか。#51 の判定までは使わない。
  ///
  /// Debug ビルドに限り、実機確認のため起動引数で有効にできる:
  /// `-UtterDebugModifierOnlyShortcut YES`（修飾キー単独）、`-UtterDebugEscapeCapture YES`（Esc 捕捉）
  private static func capabilities() -> ShortcutCapabilities {
    #if DEBUG
      let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      func enabled(_ name: String) -> Bool {
        (arguments[name] as? String).map { ["yes", "true", "1"].contains($0.lowercased()) } ?? false
      }
      return ShortcutCapabilities(
        supportsModifierOnly: enabled("UtterDebugModifierOnlyShortcut"),
        supportsEscapeCapture: enabled("UtterDebugEscapeCapture"))
    #else
      return .keyCombinationsOnly
    #endif
  }

  /// 起動時の割当。設定の保存（版2設定）が入るまでは割当なしで、何も登録しない。
  ///
  /// Debug ビルドに限り、実機確認のため起動引数で割り当てられる:
  /// `open utter.app --args -UtterDebugRecordShortcut ctrl+option+k -UtterDebugRecordShortcutMode ptt`
  /// 修飾キー単独は `fn`・`right-option` 等（`-UtterDebugModifierOnlyShortcut YES` も必要）
  private static func initialSetting() -> GlobalShortcutSetting? {
    #if DEBUG
      // 保存済みの設定（defaults write）は読まず、起動引数だけを見る
      let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      guard let text = arguments["UtterDebugRecordShortcut"] as? String else { return nil }
      let mode: ShortcutTriggerMode =
        arguments["UtterDebugRecordShortcutMode"] as? String == "ptt" ? .pushToTalk : .toggle
      if let key = ShortcutNotation.parseModifierKey(text) {
        return GlobalShortcutSetting(modifierKey: key, mode: mode)
      }
      guard let combination = ShortcutNotation.parse(text) else { return nil }
      return GlobalShortcutSetting(combination: combination, mode: mode)
    #else
      return nil
    #endif
  }
}
