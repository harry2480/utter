/// HUD の表示時間の設定（REC-03, REC-05, 4.1節）。既定値は Phase 0 前の暫定値。
public struct HUDConfiguration: Hashable, Sendable {
  /// 失敗を表示し続ける時間の既定値（暫定3秒）。
  public static let defaultErrorDisplayDuration: Duration = .seconds(3)
  /// セッション終了後に上限到達・退避の通知を残す時間の既定値（暫定3秒）。
  public static let defaultLimitNoticeDisplayDuration: Duration = .seconds(3)
  /// 挿入完了（挿入先のアプリ名）だけを残す時間の既定値（暫定1.5秒）。
  public static let defaultCompletionDisplayDuration: Duration = .milliseconds(1500)

  /// 失敗を表示し続ける時間。経過後、アプリは `SessionStateMachine.dismissError()` を呼ぶ。
  public let errorDisplayDuration: Duration
  /// 上限到達で自動停止した・ローカル整形へ退避したセッションの挿入完了後に、通知を残す時間（REC-05, 4.1節）。
  /// 名前は上限到達の通知を追加したときのまま、退避の通知にも同じ時間を使う。
  public let limitNoticeDisplayDuration: Duration
  /// 通知のないセッションの挿入完了を残す時間（REC-03）。通知もあるときは `limitNoticeDisplayDuration` を使う。
  public let completionDisplayDuration: Duration

  public init() {
    errorDisplayDuration = Self.defaultErrorDisplayDuration
    limitNoticeDisplayDuration = Self.defaultLimitNoticeDisplayDuration
    completionDisplayDuration = Self.defaultCompletionDisplayDuration
  }

  public init(
    errorDisplayDuration: Duration,
    limitNoticeDisplayDuration: Duration,
    completionDisplayDuration: Duration = HUDConfiguration.defaultCompletionDisplayDuration
  ) throws(HUDConfigurationError) {
    guard errorDisplayDuration > .zero else { throw .nonPositiveErrorDisplayDuration }
    guard limitNoticeDisplayDuration > .zero else {
      throw .nonPositiveLimitNoticeDisplayDuration
    }
    guard completionDisplayDuration > .zero else {
      throw .nonPositiveCompletionDisplayDuration
    }
    self.errorDisplayDuration = errorDisplayDuration
    self.limitNoticeDisplayDuration = limitNoticeDisplayDuration
    self.completionDisplayDuration = completionDisplayDuration
  }
}

public enum HUDConfigurationError: Error, Hashable, Sendable {
  case nonPositiveErrorDisplayDuration
  case nonPositiveLimitNoticeDisplayDuration
  case nonPositiveCompletionDisplayDuration
}
