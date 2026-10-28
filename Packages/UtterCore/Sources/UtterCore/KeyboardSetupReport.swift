import Foundation

/// キーボード拡張が本体アプリのセットアップ画面に伝える報告（#200）。
///
/// 本体アプリからは、キーボードが追加されたか・フルアクセスが有効かを公開 API で確かめられないため、
/// キーボード拡張が表示されたときに App Group に残し（UtterPersistence の `KeyboardSetupReportStore`）、本体アプリが読む。
/// 報告があること自体が「キーボードが表示された（追加済み）」を表す。
/// 持つのは観測時刻とフルアクセスの有無だけで、入力した文字・本文・秘密情報は持たない（iOS-IPC-04, iAC-08）。
public struct KeyboardSetupReport: Hashable, Sendable, Codable {
  /// キーボード拡張が表示され、この報告を残した時刻
  public var observedAt: Date
  /// そのときにフルアクセスが有効だったか
  public var hasFullAccess: Bool

  public init(observedAt: Date, hasFullAccess: Bool) {
    self.observedAt = observedAt
    self.hasFullAccess = hasFullAccess
  }
}
