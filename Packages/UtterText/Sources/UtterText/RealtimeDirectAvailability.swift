/// Realtime Direct に対する前面アプリの対応状況（2.2節, AC-15, AC-20）。互換性表の検証結果を呼び出し側が渡す。
///
/// どちらも実機で確かめたアプリだけ `true` にする。未検証・不明のアプリは `unsupported` のままにし、
/// Realtime Direct を自動的に無効にする（AC-15）。
public struct RealtimeDirectAppSupport: Hashable, Sendable {
  /// 入力欄の値と選択範囲を読み戻せ、指定範囲だけを置き換えられる（安全な範囲追跡）
  public var tracksRange: Bool
  /// 逐次の書き込みをアプリ標準の Undo でも取り消せる（INS-07）
  public var supportsUndo: Bool

  /// 未検証のアプリの既定値
  public static let unsupported = RealtimeDirectAppSupport(tracksRange: false, supportsUndo: false)

  public init(tracksRange: Bool, supportsUndo: Bool) {
    self.tracksRange = tracksRange
    self.supportsUndo = supportsUndo
  }
}

/// Realtime Direct を使えない理由（AC-15）。
public enum RealtimeDirectUnavailableReason: Hashable, Sendable, CaseIterable {
  /// 利用者が実験機能を有効にしていない
  case disabledByUser
  /// 前面アプリで安全な範囲追跡が確認されていない
  case rangeTrackingUnsupported
  /// 前面アプリで Undo が確認されていない
  case undoUnsupported
  /// ターミナル系のアプリ。逐次の書き込みが入力中のコマンドを書き換えるため使わない（INS-03, AC-08）
  case terminal
  /// 開始時に入力対象を特定できない
  case targetUnknown
  /// 開始時に入力欄の値や選択範囲を読み取れない、または選択範囲が値の範囲外や書記素クラスター（絵文字・結合文字など）の途中を指す
  case fieldUnreadable
  /// 開始時にテキストが選択されている。選択したテキストの置き換えは取り消しの対象にしないため、カーソル位置からだけ始める
  case selectionNotEmpty
}

/// Realtime Direct を使えるかを決める条件（AC-15）。
///
/// 使えない場合、呼び出し側は Realtime Preview（停止後に一括挿入）で処理する。
public struct RealtimeDirectRequirements: Hashable, Sendable {
  /// 利用者が実験機能を有効にした
  public var isEnabled: Bool
  public var appSupport: RealtimeDirectAppSupport
  /// ターミナル系のアプリ（`InsertionPlan.isTerminal`）
  public var isTerminal: Bool

  public init(isEnabled: Bool, appSupport: RealtimeDirectAppSupport, isTerminal: Bool) {
    self.isEnabled = isEnabled
    self.appSupport = appSupport
    self.isTerminal = isTerminal
  }

  /// 使えない理由をすべて返す。空なら使える。
  public var unavailableReasons: Set<RealtimeDirectUnavailableReason> {
    var reasons: Set<RealtimeDirectUnavailableReason> = []
    if !isEnabled {
      reasons.insert(.disabledByUser)
    }
    if !appSupport.tracksRange {
      reasons.insert(.rangeTrackingUnsupported)
    }
    if !appSupport.supportsUndo {
      reasons.insert(.undoUnsupported)
    }
    if isTerminal {
      reasons.insert(.terminal)
    }
    return reasons
  }
}
