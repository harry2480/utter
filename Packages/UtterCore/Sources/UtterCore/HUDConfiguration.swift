/// HUD の表示時間の設定（REC-03, REC-05）。既定値は Phase 0 前の暫定値。
public struct HUDConfiguration: Hashable, Sendable {
  /// 失敗を表示し続ける時間の既定値（暫定3秒）。
  public static let defaultErrorDisplayDuration: Duration = .seconds(3)
  /// セッション終了後に上限到達の通知を残す時間の既定値（暫定3秒）。
  public static let defaultLimitNoticeDisplayDuration: Duration = .seconds(3)

  /// 失敗を表示し続ける時間。経過後、アプリは `SessionStateMachine.dismissError()` を呼ぶ。
  public let errorDisplayDuration: Duration
  /// 上限到達で自動停止したセッションの挿入完了後に、通知を残す時間（REC-05）。
  public let limitNoticeDisplayDuration: Duration

  public init() {
    errorDisplayDuration = Self.defaultErrorDisplayDuration
    limitNoticeDisplayDuration = Self.defaultLimitNoticeDisplayDuration
  }

  public init(
    errorDisplayDuration: Duration,
    limitNoticeDisplayDuration: Duration
  ) throws(HUDConfigurationError) {
    guard errorDisplayDuration > .zero else { throw .nonPositiveErrorDisplayDuration }
    guard limitNoticeDisplayDuration > .zero else {
      throw .nonPositiveLimitNoticeDisplayDuration
    }
    self.errorDisplayDuration = errorDisplayDuration
    self.limitNoticeDisplayDuration = limitNoticeDisplayDuration
  }
}

public enum HUDConfigurationError: Error, Hashable, Sendable {
  case nonPositiveErrorDisplayDuration
  case nonPositiveLimitNoticeDisplayDuration
}
