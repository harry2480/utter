import UtterCore

/// 録音のグローバルショートカットの登録と、押下・解放のセッション操作への変換（REC-01, REC-02）。
///
/// 通常のキー組み合わせ（修飾キー＋キー）だけを扱う。修飾キー単独と、セッション中だけの Esc 捕捉は
/// イベントタップと追加権限が必要なため、#51 の判定後に別途実装する（要件定義 11章）。
///
/// 割当の検証は UtterCore の `ShortcutValidator`、押下・解放の解釈は `ShortcutInterpreter` が行い、
/// ここは OS の登録と、両者・アプリの結線だけを持つ。
@MainActor
final class GlobalShortcutController {
  /// 競合検出で使う utter の録音ショートカットの ID
  static let recordBindingID = "utter.record"

  private let registrar: any HotKeyRegistering
  private let systemShortcuts: () -> [ShortcutBinding]
  private let currentPhase: () -> SessionPhase
  private let perform: (ShortcutCommand) -> Void
  /// 修飾キー単独は #51 の判定まで受け付けない
  private let validator = ShortcutValidator(
    capabilities: ShortcutCapabilities(supportsModifierOnly: false))
  private var interpreter = ShortcutInterpreter(mode: .toggle)
  private var translator = HotKeyEventTranslator()
  private var registration: HotKeyRegistrationID?

  private(set) var status: GlobalShortcutStatus = .unassigned

  /// - Parameters:
  ///   - systemShortcuts: 競合を検出する相手（有効なシステムのショートカット）。割当のたびに取得する
  ///   - currentPhase: セッションの現在の状態
  ///   - perform: 実行するセッション操作
  init(
    registrar: any HotKeyRegistering,
    systemShortcuts: @escaping () -> [ShortcutBinding],
    currentPhase: @escaping () -> SessionPhase,
    perform: @escaping (ShortcutCommand) -> Void
  ) {
    self.registrar = registrar
    self.systemShortcuts = systemShortcuts
    self.currentPhase = currentPhase
    self.perform = perform
  }

  isolated deinit {
    if let registration {
      registrar.unregister(registration)
    }
  }

  /// 割当を置き換える。`nil` なら登録しない（既定のショートカットは要件で決まっていない）。
  ///
  /// 前の割当は先に解除する。新しい割当を使えないときは何も登録せず、理由を `status` に残す。
  @discardableResult
  func apply(_ setting: GlobalShortcutSetting?) -> GlobalShortcutStatus {
    unregister()
    status = register(setting)
    return status
  }

  /// スリープ等で解放を取りこぼしうるときに、押下中の状態を破棄する。
  func reset() {
    translator.reset()
    interpreter.reset()
  }

  /// 登録したホットキーのイベントを受け取る。
  func receive(_ phase: HotKeyPhase) {
    guard let input = translator.translate(phase) else { return }
    if case .consumed(let command?) = interpreter.handle(input, phase: currentPhase()) {
      perform(command)
    }
  }

  private func register(_ setting: GlobalShortcutSetting?) -> GlobalShortcutStatus {
    guard let setting else { return .unassigned }
    let issues = validator.issues(
      for: setting.combination, bindingID: Self.recordBindingID, registered: systemShortcuts())
    guard issues.isEmpty else {
      return .unavailable(setting, .invalid(issues))
    }
    let spec: CarbonHotKeySpec
    switch CarbonHotKeySpec.make(for: setting.combination) {
    case .success(let made): spec = made
    case .failure(let issue): return .unavailable(setting, .unsupported(issue))
    }
    interpreter.mode = setting.mode
    let result = registrar.register(spec) { [weak self] phase in
      self?.receive(phase)
    }
    switch result {
    case .success(let id):
      registration = id
      return .active(setting)
    case .failure(let failure):
      return .unavailable(setting, .registrationFailed(failure))
    }
  }

  private func unregister() {
    if let registration {
      registrar.unregister(registration)
    }
    registration = nil
    reset()
  }
}

/// 録音ショートカットの割当。
struct GlobalShortcutSetting: Hashable, Sendable {
  let combination: KeyCombination
  let mode: ShortcutTriggerMode
}

/// 録音ショートカットの状態。メニューに表示する。
enum GlobalShortcutStatus: Hashable, Sendable {
  /// 割当なし
  case unassigned
  /// 登録済み
  case active(GlobalShortcutSetting)
  /// 割当はあるが使えない
  case unavailable(GlobalShortcutSetting, GlobalShortcutUnavailableReason)
}

enum GlobalShortcutUnavailableReason: Hashable, Sendable {
  /// 割当の検証で問題がある（Esc の予約、システムのショートカットとの競合、修飾キー単独）
  case invalid([ShortcutValidationIssue])
  /// RegisterEventHotKey で扱えない組み合わせ
  case unsupported(HotKeySpecIssue)
  /// 登録に失敗した（他アプリとの競合など）
  case registrationFailed(HotKeyRegistrationFailure)
}
