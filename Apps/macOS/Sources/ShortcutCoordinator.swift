import AppKit
import Observation
import UtterCore

/// 録音ショートカットをアプリに結線する（REC-01, REC-02）。
///
/// 押下・解放の解釈には `SessionCoordinator` の現在の状態を使い、セッション操作はそのまま `SessionCoordinator` へ渡す。
/// ショートカット以外の要因でセッションの状態が変わったら `sessionPhaseDidChange()` を呼ぶ
/// （Esc の捕捉をセッション中だけ有効にするため）。
///
/// 割当は設定（版2設定）の録音ショートカットと録音の操作方式で、設定画面で変わったら `updateSetting(_:)` で受け取り、
/// 進行中のセッションが終わってから登録し直す。
/// 修飾キー単独と Esc 捕捉（#51 の判定待ち）は既定で無効（`ShortcutCapabilities.keyCombinationsOnly`）。
@MainActor
@Observable
final class ShortcutCoordinator {
  private(set) var status: GlobalShortcutStatus = .unassigned
  private(set) var escapeStatus: EscapeCaptureStatus = .off

  @ObservationIgnored private var controller: GlobalShortcutController?
  @ObservationIgnored private var resetObservers: [any NSObjectProtocol] = []
  @ObservationIgnored private var permissionTimer: Timer?
  /// 起動引数の割当（Debug ビルドだけ）を使い、設定の変更に従わないか
  @ObservationIgnored private let usesDebugSetting: Bool
  /// HUD に出す停止・キャンセルのキーが変わりうるとき（状態を読み直すたび）に呼ぶ
  @ObservationIgnored private let onKeyHintsChange: @MainActor (HUDKeyHints) -> Void

  /// 権限の取り消し・許可を確かめる間隔（仮置き。権限の変化を検出する OS の通知がないため定期的に確かめる。
  /// CGPreflightListenEventAccess・AXIsProcessTrusted は軽い呼び出しで、イベントタップを使う機能が有効なときだけ動かす）
  private static let permissionCheckInterval: TimeInterval = 5

  /// - Parameters:
  ///   - setting: 起動時の割当（保存された設定から作る）。`nil` なら何も登録しない
  ///   - registrar: ホットキーの登録。Edit Mode のショートカット（`EditModeShortcut`）と同じものを渡す
  ///   - currentPhase: セッションの現在の状態
  ///   - perform: 実行するセッション操作
  ///   - onKeyHintsChange: HUD に出す停止・キャンセルのキー（REC-03）。状態を読み直すたびに呼ぶ
  init(
    setting: GlobalShortcutSetting?,
    registrar: any HotKeyRegistering,
    currentPhase: @escaping @MainActor () -> SessionPhase,
    perform: @escaping @MainActor (ShortcutCommand) -> Void,
    onKeyHintsChange: @escaping @MainActor (HUDKeyHints) -> Void = { _ in }
  ) {
    self.onKeyHintsChange = onKeyHintsChange
    let debugSetting = Self.debugSetting()
    usesDebugSetting = debugSetting != nil
    let controller = GlobalShortcutController(
      registrar: registrar,
      tapFactory: CGKeyEventTapFactory(),
      permissions: SystemEventTapPermissions(),
      capabilities: Self.capabilities(),
      systemShortcuts: SystemShortcuts.loadEnabledBindings,
      currentPhase: currentPhase,
      perform: perform
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
    controller.apply(debugSetting ?? setting)
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

  /// 設定画面で割当（録音ショートカット・録音の操作方式）が変わったときに呼ぶ。
  ///
  /// 待機中ならすぐに、セッション中なら待機に戻ってから登録し直す。同じ割当なら何もしない。
  /// 起動引数で割り当てたとき（Debug ビルドだけ）は、その割当のまま変えない
  func updateSetting(_ setting: GlobalShortcutSetting?) {
    guard !usesDebugSetting else { return }
    controller?.update(setting)
  }

  /// セッションの状態が、ショートカット以外の要因（認識の完了・自動停止・メニューの操作など）で変わったときに呼ぶ
  func sessionPhaseDidChange() {
    controller?.sessionPhaseDidChange()
  }

  private func syncStatus() {
    guard let controller else { return }
    status = controller.status
    escapeStatus = controller.escapeStatus
    onKeyHintsChange(HUDKeyHints(status: status, escapeStatus: escapeStatus))
  }

  /// 修飾キー単独・Esc 捕捉を使うか。#51 の判定までは使わない。設定画面の Esc の説明にも使う。
  ///
  /// Debug ビルドに限り、実機確認のため起動引数で有効にできる:
  /// `-UtterDebugModifierOnlyShortcut YES`（修飾キー単独）、`-UtterDebugEscapeCapture YES`（Esc 捕捉）
  static func capabilities() -> ShortcutCapabilities {
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

  /// 起動引数の割当。保存された設定より優先する。Release ビルドと、起動引数がないときは `nil`。
  ///
  /// Debug ビルドに限り、実機確認のため起動引数で割り当てられる:
  /// `open utter.app --args -UtterDebugRecordShortcut ctrl+option+k -UtterDebugRecordShortcutMode ptt`
  /// 修飾キー単独は `fn`・`right-option` 等（`-UtterDebugModifierOnlyShortcut YES` も必要）
  private static func debugSetting() -> GlobalShortcutSetting? {
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
