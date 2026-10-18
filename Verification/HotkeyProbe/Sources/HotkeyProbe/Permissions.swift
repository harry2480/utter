import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hid

/// 入力監視・アクセシビリティ等の権限の確認と要求。
///
/// 権限は「責任のあるプロセス」に紐づく。Terminal から実行すると Terminal（iTerm 等ならそのアプリ）に
/// 対して判定・要求されるため、結果は実行したターミナルアプリの許可状態を表す。
enum Permissions {
  struct Snapshot: Sendable {
    /// 入力監視（CGPreflightListenEventAccess）
    let listenEvent: Bool
    /// イベント送信（CGPreflightPostEventAccess。システム設定ではアクセシビリティ）
    let postEvent: Bool
    /// アクセシビリティ（AXIsProcessTrusted）
    let accessibility: Bool
    /// 入力監視（IOHIDCheckAccess）
    let hidListen: String
    /// Secure Event Input（パスワード欄など）が有効か。有効中はキーボードのイベントタップに届かない
    let secureInput: Bool
  }

  static func snapshot() -> Snapshot {
    Snapshot(
      listenEvent: CGPreflightListenEventAccess(),
      postEvent: CGPreflightPostEventAccess(),
      accessibility: AXIsProcessTrusted(),
      hidListen: describe(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)),
      secureInput: IsSecureEventInputEnabled()
    )
  }

  @MainActor
  static func log(_ snapshot: Snapshot, to log: ProbeLog) {
    log.write("perm", "入力監視 CGPreflightListenEventAccess=\(snapshot.listenEvent)")
    log.write("perm", "入力監視 IOHIDCheckAccess(ListenEvent)=\(snapshot.hidListen)")
    log.write("perm", "イベント送信 CGPreflightPostEventAccess=\(snapshot.postEvent)")
    log.write("perm", "アクセシビリティ AXIsProcessTrusted=\(snapshot.accessibility)")
    log.write("perm", "SecureEventInput 有効=\(snapshot.secureInput)")
  }

  /// 入力監視の許可ダイアログを要求する。ダイアログの操作は人が行う。
  static func requestListenEvent() -> Bool {
    CGRequestListenEventAccess()
  }

  /// アクセシビリティの許可ダイアログを要求する。ダイアログの操作は人が行う。
  static func requestAccessibility() -> Bool {
    // kAXTrustedCheckOptionPrompt の実体の文字列。C のグローバル変数は Swift 6 で並行安全でないため直接使わない
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  private static func describe(_ access: IOHIDAccessType) -> String {
    switch access {
    case kIOHIDAccessTypeGranted: "granted"
    case kIOHIDAccessTypeDenied: "denied"
    case kIOHIDAccessTypeUnknown: "unknown（未確認。要求すると許可ダイアログが出る）"
    default: "other(\(access.rawValue))"
    }
  }
}
