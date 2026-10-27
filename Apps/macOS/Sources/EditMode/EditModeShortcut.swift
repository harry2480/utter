import Observation
import UtterCore

/// Edit Mode を始めるグローバルショートカットの登録（AC-14, REC-02）。
///
/// 録音ショートカットとは別のキーにし、既定は未割り当て（何も登録しない）。押下だけを受け取り、`onPress` を呼ぶ
/// （押すたびに始める・止める Toggle。Push-to-talk は扱わない）。
/// 通常のキー組み合わせだけを RegisterEventHotKey で登録する（権限不要, PERM-01）。修飾キー単独は扱わない。
/// 録音ショートカットと同じキー・システムのショートカットとの競合・Esc の予約は、登録の前に確かめて登録しない。
/// 押されたキーはログに出さない。
@MainActor
@Observable
final class EditModeShortcut {
  /// 競合検出で使う Edit Mode のショートカットの ID
  nonisolated static let bindingID = "utter.editMode"

  /// 登録の状態。メニューの表示に使う
  private(set) var status: EditModeShortcutStatus = .unassigned
  @ObservationIgnored private let registrar: any HotKeyRegistering
  @ObservationIgnored private let systemShortcuts: () -> [ShortcutBinding]
  @ObservationIgnored private let onPress: @MainActor () -> Void
  @ObservationIgnored private var registration: HotKeyRegistrationID?
  /// 今の割当（Edit Mode のショートカットと、比べた録音ショートカット）。同じ割当なら登録し直さない
  @ObservationIgnored private var assignment: Assignment?

  private struct Assignment: Equatable {
    let shortcut: KeyCombination?
    let recordingShortcut: KeyCombination?
  }

  /// - Parameters:
  ///   - registrar: ホットキーの登録。録音ショートカットと同じものを渡す（Carbon のイベントハンドラを1つにするため）
  ///   - systemShortcuts: 競合を検出する相手（有効なシステムのショートカット）。割当のたびに取得する
  ///   - onPress: ショートカットが押されたときに呼ぶ
  init(
    registrar: any HotKeyRegistering,
    systemShortcuts: @escaping () -> [ShortcutBinding],
    onPress: @escaping @MainActor () -> Void
  ) {
    self.registrar = registrar
    self.systemShortcuts = systemShortcuts
    self.onPress = onPress
  }

  isolated deinit {
    if let registration {
      registrar.unregister(registration)
    }
  }

  /// 割当を置き換える。`shortcut` が `nil` なら何も登録しない（未割り当て）。
  ///
  /// 前の割当は先に解除する。同じ割当なら登録し直さない（登録失敗の表示をそのまま残す）。
  /// - Parameter recordingShortcut: 録音ショートカット。同じキーなら登録しない
  @discardableResult
  func apply(_ shortcut: KeyCombination?, recordingShortcut: KeyCombination?)
    -> EditModeShortcutStatus
  {
    let next = Assignment(shortcut: shortcut, recordingShortcut: recordingShortcut)
    guard next != assignment else { return status }
    assignment = next
    unregister()
    status = register(shortcut, recordingShortcut: recordingShortcut)
    return status
  }

  private func register(_ shortcut: KeyCombination?, recordingShortcut: KeyCombination?)
    -> EditModeShortcutStatus
  {
    guard let shortcut else { return .unassigned }
    guard shortcut != recordingShortcut else {
      return .unavailable(shortcut, .sameAsRecording)
    }
    var registered = systemShortcuts()
    if let recordingShortcut {
      registered.append(
        ShortcutBinding(
          id: GlobalShortcutController.recordBindingID, combination: recordingShortcut))
    }
    let issues = ShortcutValidator(capabilities: .keyCombinationsOnly).issues(
      for: shortcut, bindingID: Self.bindingID, registered: registered)
    guard issues.isEmpty else { return .unavailable(shortcut, .invalid(issues)) }
    let spec: CarbonHotKeySpec
    switch CarbonHotKeySpec.make(for: shortcut) {
    case .success(let made): spec = made
    case .failure(let issue): return .unavailable(shortcut, .unsupported(issue))
    }
    let result = registrar.register(spec) { [weak self] phase in
      guard phase == .pressed else { return }
      self?.onPress()
    }
    switch result {
    case .success(let id):
      registration = id
      return .active(shortcut)
    case .failure(let failure):
      return .unavailable(shortcut, .registrationFailed(failure))
    }
  }

  private func unregister() {
    if let registration {
      registrar.unregister(registration)
    }
    registration = nil
  }
}

/// Edit Mode のショートカットの状態。メニューに表示する。
enum EditModeShortcutStatus: Hashable, Sendable {
  /// 割当なし（既定）。Edit Mode を使わない
  case unassigned
  /// 登録済み
  case active(KeyCombination)
  /// 割当はあるが使えない
  case unavailable(KeyCombination, EditModeShortcutUnavailableReason)
}

enum EditModeShortcutUnavailableReason: Hashable, Sendable {
  /// 録音ショートカットと同じキー
  case sameAsRecording
  /// 割当の検証で問題がある（Esc の予約、システムのショートカット・録音ショートカットとの競合、修飾キー単独）
  case invalid([ShortcutValidationIssue])
  /// RegisterEventHotKey で扱えない組み合わせ
  case unsupported(HotKeySpecIssue)
  /// 登録に失敗した（他アプリとの競合など）
  case registrationFailed(HotKeyRegistrationFailure)
}

extension EditModeShortcutStatus {
  /// メニューに出す文言。キーの組み合わせは割当の表示（`ShortcutNotation`）だけを使う
  var text: String {
    switch self {
    case .unassigned:
      "Edit Mode: ショートカット未割り当て（設定画面で割り当てると使えます）"
    case .active(let shortcut):
      "Edit Mode: \(ShortcutNotation.display(shortcut))"
    case .unavailable(let shortcut, .sameAsRecording):
      "Edit Mode: \(ShortcutNotation.display(shortcut)) は録音と同じキーのため使えません"
    case .unavailable(let shortcut, _):
      "Edit Mode: \(ShortcutNotation.display(shortcut)) を登録できません（ほかの割当と重なっている可能性があります）"
    }
  }
}
