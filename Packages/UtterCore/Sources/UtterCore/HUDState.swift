/// 状態機械の変化から HUD の表示内容を導く（REC-03, REC-05）。
///
/// アプリは `SessionStateMachine` を変更するたびに `update(from:at:)` を呼び、
/// `content(at:)` で表示内容を得る。時刻は引数で受け取り、タイマーなどの OS 実装は持たない。
/// 次に表示を更新すべき時刻は `errorDismissDeadline` と `noticeExpiry` で知らせる。
public struct HUDState: Hashable, Sendable {
  public let configuration: HUDConfiguration

  private var phase: SessionPhase = .idle
  private var sessionID: SessionID?
  private var stopReason: RecordingStopReason?
  /// 失敗の表示に添える理由。失敗の表示中だけ持つ
  private var failureNotice: HUDNotice?
  /// 失敗の表示を終える時刻
  public private(set) var errorDismissDeadline: ContinuousClock.Instant?
  /// セッション終了後に残している通知
  private var lingeringNotice: HUDNotice?
  /// 残している通知を消す時刻
  public private(set) var noticeExpiry: ContinuousClock.Instant?

  public init(configuration: HUDConfiguration = HUDConfiguration()) {
    self.configuration = configuration
  }

  /// 状態機械の現在の状態を反映する。
  /// - Parameter failureNotice: 失敗の表示に添える理由（`error` のときだけ使う）。`update(phase:activeSession:failureNotice:at:)` を参照
  public mutating func update(
    from machine: SessionStateMachine, failureNotice: HUDNotice? = nil,
    at now: ContinuousClock.Instant
  ) {
    update(
      phase: machine.phase, activeSession: machine.activeSession, failureNotice: failureNotice,
      at: now)
  }

  /// セッションの状態を反映する。状態が変わるたびに呼ぶ（同じ状態で何度呼んでもよい）。
  ///
  /// 挿入中から待機に戻ったとき（正常完了）だけ、上限到達の通知を `limitNoticeDisplayDuration` だけ残す。
  /// キャンセルや失敗表示の終了で待機に戻ったときは残さない。
  ///
  /// `failureNotice` は失敗の表示に添える理由で、録音の停止理由の通知より優先して表示する。
  /// 失敗の表示に入ったときに渡した値を、失敗の表示を終えるまで保つ（表示中に `nil` で呼んでも消さない）。
  /// `error` 以外では使わない。
  public mutating func update(
    phase newPhase: SessionPhase,
    activeSession: ActiveSession?,
    failureNotice: HUDNotice? = nil,
    at now: ContinuousClock.Instant
  ) {
    let previousPhase = phase
    defer { phase = newPhase }

    guard newPhase != .idle, let activeSession else {
      if previousPhase == .inserting, let stopReason, let notice = HUDNotice(stopReason: stopReason)
      {
        lingeringNotice = notice
        noticeExpiry = now.advanced(by: configuration.limitNoticeDisplayDuration)
      } else if previousPhase != .idle {
        clearLingeringNotice()
      }
      sessionID = nil
      stopReason = nil
      self.failureNotice = nil
      errorDismissDeadline = nil
      return
    }

    let isNewSession = activeSession.id != sessionID
    if isNewSession {
      clearLingeringNotice()
      sessionID = activeSession.id
    }
    stopReason = activeSession.stopReason

    if case .error = newPhase {
      if isNewSession || errorDismissDeadline == nil {
        errorDismissDeadline = now.advanced(by: configuration.errorDisplayDuration)
        self.failureNotice = failureNotice
      } else if let failureNotice {
        self.failureNotice = failureNotice
      }
    } else {
      errorDismissDeadline = nil
      self.failureNotice = nil
    }
  }

  /// `now` の時点で HUD に表示する内容。何も表示しないときは `nil`。
  public func content(at now: ContinuousClock.Instant) -> HUDContent? {
    if let status = HUDStatus(phase: phase) {
      return HUDContent(
        status: status, notice: failureNotice ?? stopReason.flatMap(HUDNotice.init(stopReason:)))
    }
    guard let lingeringNotice, let noticeExpiry, now < noticeExpiry else { return nil }
    return HUDContent(status: nil, notice: lingeringNotice)
  }

  private mutating func clearLingeringNotice() {
    lingeringNotice = nil
    noticeExpiry = nil
  }
}
