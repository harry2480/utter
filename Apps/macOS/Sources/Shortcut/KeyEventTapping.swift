import CoreGraphics
import UtterCore

/// イベントタップ（CGEventTap）の作成（REC-01, REC-02。#51 の判定待ち）。
/// 本番は `CGKeyEventTapFactory`、テストは Stub を使う。
///
/// 修飾キー単独ショートカットと Esc 捕捉の capability（`ShortcutCapabilities`）が有効なときだけ使う。
/// 無効なら作成しない（PERM-01）。
@MainActor
protocol KeyEventTapFactory: AnyObject {
  /// タップを作成する。権限がない等で作成できなければ `nil`。
  ///
  /// - Parameters:
  ///   - events: 受け取るイベントの種類
  ///   - enabled: 作成直後に有効にするか
  ///   - handler: イベントごとに呼ぶ。`true` で通し、`false` で止める（`listen` では止められない）
  ///   - onDisabled: OS がタップを無効化したとき（タイムアウト・利用者の入力）に呼ぶ。再有効化は呼び出し側が行う
  func makeTap(
    mode: KeyEventTapMode,
    events: Set<KeyTapEventKind>,
    enabled: Bool,
    handler: @escaping @MainActor (KeyTapEvent) -> Bool,
    onDisabled: @escaping @MainActor () -> Void
  ) -> (any KeyEventTap)?
}

/// 作成済みのイベントタップ。`invalidate` 後はハンドラを呼ばない。
@MainActor
protocol KeyEventTap: AnyObject {
  var isEnabled: Bool { get }
  func setEnabled(_ enabled: Bool)
  func invalidate()
}

/// イベントタップの種類と、必要な権限。
enum KeyEventTapMode: Hashable, Sendable {
  /// 監視のみ（listenOnly）。イベントを止めない。入力監視の権限が必要
  case listen
  /// 能動的なフィルタ（defaultTap）。イベントを止められる。アクセシビリティの権限が必要
  case filter

  var requiredPermission: EventTapPermission {
    switch self {
    case .listen: .inputMonitoring
    case .filter: .accessibility
    }
  }
}

/// イベントタップに必要な権限（PERM-01, PERM-02）。
enum EventTapPermission: Hashable, Sendable {
  /// 入力監視（CGPreflightListenEventAccess）
  case inputMonitoring
  /// アクセシビリティ（AXIsProcessTrusted）
  case accessibility
}

/// 権限の確認と要求。本番は `SystemEventTapPermissions`、テストは Stub を使う。
@MainActor
protocol EventTapPermissionChecking: AnyObject {
  /// 許可されているか。ダイアログは出さない
  func isGranted(_ permission: EventTapPermission) -> Bool
  /// 許可を求める（システムのダイアログ・システム設定を開く）。利用者の操作を受けて呼ぶ
  func request(_ permission: EventTapPermission)
}

/// タップのコールバックから取り出した値。CGEvent そのものは持たない。
///
/// 通常のキーのキーコードは、Esc と修飾キーの判定にだけ使い、記録しない。
struct KeyTapEvent: Hashable, Sendable {
  let kind: KeyTapEventKind
  let keyCode: Int
  /// CGEventFlags の値（汎用マスクとデバイス依存の左右ビット）
  let flags: UInt64
  let isRepeat: Bool

  init(kind: KeyTapEventKind, keyCode: Int, flags: UInt64 = 0, isRepeat: Bool = false) {
    self.kind = kind
    self.keyCode = keyCode
    self.flags = flags
    self.isRepeat = isRepeat
  }

  /// 押されている修飾キー（左右の区別なし）
  var modifiers: ShortcutModifiers {
    var result: ShortcutModifiers = []
    let flags = CGEventFlags(rawValue: flags)
    if flags.contains(.maskCommand) { result.insert(.command) }
    if flags.contains(.maskAlternate) { result.insert(.option) }
    if flags.contains(.maskControl) { result.insert(.control) }
    if flags.contains(.maskShift) { result.insert(.shift) }
    if flags.contains(.maskSecondaryFn) { result.insert(.function) }
    return result
  }
}

enum KeyTapEventKind: Hashable, Sendable {
  case keyDown
  case keyUp
  case flagsChanged
}
