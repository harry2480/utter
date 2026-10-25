/// 状態機械の変化から HUD の表示内容を導く（REC-03, REC-05, 4.1節）。
///
/// アプリは `SessionStateMachine` を変更するたびに `update(from:at:)` を呼び、
/// `content(at:)` で表示内容を得る。ローカル整形へ退避したときは `recordRefinementFallback(_:for:)` で知らせる。時刻は引数で受け取り、タイマーなどの OS 実装は持たない。
/// 次に表示を更新すべき時刻は `errorDismissDeadline` と `noticeExpiry` で知らせる。
public struct HUDState: Hashable, Sendable {
  public let configuration: HUDConfiguration

  private var phase: SessionPhase = .idle
  private var sessionID: SessionID?
  private var stopReason: RecordingStopReason?
  /// 進行中のセッションがローカル整形へ退避した理由
  private var refinementFallback: RefinementFallbackNotice?
  /// 失敗の表示を終える時刻
  public private(set) var errorDismissDeadline: ContinuousClock.Instant?
  /// セッション終了後に残している通知
  private var lingeringNotices: [HUDNotice] = []
  /// 残している通知を消す時刻
  public private(set) var noticeExpiry: ContinuousClock.Instant?

  public init(configuration: HUDConfiguration = HUDConfiguration()) {
    self.configuration = configuration
  }

  /// 状態機械の現在の状態を反映する。
  public mutating func update(from machine: SessionStateMachine, at now: ContinuousClock.Instant) {
    update(phase: machine.phase, activeSession: machine.activeSession, at: now)
  }

  /// セッションの状態を反映する。状態が変わるたびに呼ぶ（同じ状態で何度呼んでもよい）。
  ///
  /// 挿入中から待機に戻ったとき（正常完了）だけ、上限到達・退避の通知を `limitNoticeDisplayDuration` だけ残す。
  /// キャンセルや失敗表示の終了で待機に戻ったときは残さない。
  public mutating func update(
    phase newPhase: SessionPhase,
    activeSession: ActiveSession?,
    at now: ContinuousClock.Instant
  ) {
    let previousPhase = phase
    defer { phase = newPhase }

    guard newPhase != .idle, let activeSession else {
      let notices = activeNotices
      if previousPhase == .inserting, !notices.isEmpty {
        lingeringNotices = notices
        noticeExpiry = now.advanced(by: configuration.limitNoticeDisplayDuration)
      } else if previousPhase != .idle {
        clearLingeringNotice()
      }
      sessionID = nil
      stopReason = nil
      refinementFallback = nil
      errorDismissDeadline = nil
      return
    }

    let isNewSession = activeSession.id != sessionID
    if isNewSession {
      clearLingeringNotice()
      sessionID = activeSession.id
      refinementFallback = nil
    }
    stopReason = activeSession.stopReason

    if case .error = newPhase {
      if isNewSession || errorDismissDeadline == nil {
        errorDismissDeadline = now.advanced(by: configuration.errorDisplayDuration)
      }
    } else {
      errorDismissDeadline = nil
    }
  }

  /// 進行中のセッションがローカル整形へ退避したことを反映する（4.1節, AC-16）。
  ///
  /// 整形の結果を受け取ったら、`SessionStateMachine` へ整形完了を知らせる前（整形中を反映した状態）に呼ぶ。
  /// 整形中でないとき、反映済みのセッションと異なるセッション（キャンセル・完了済みのセッションの遅れた結果など）の退避は無視する。
  /// 同じセッションで複数回呼んだ場合は最後の理由を表示する。
  public mutating func recordRefinementFallback(
    _ notice: RefinementFallbackNotice, for sessionID: SessionID
  ) {
    guard phase == .refining, sessionID == self.sessionID else { return }
    refinementFallback = notice
  }

  /// `now` の時点で HUD に表示する内容。何も表示しないときは `nil`。
  public func content(at now: ContinuousClock.Instant) -> HUDContent? {
    if let status = HUDStatus(phase: phase) {
      return HUDContent(status: status, notices: activeNotices)
    }
    guard !lingeringNotices.isEmpty, let noticeExpiry, now < noticeExpiry else { return nil }
    return HUDContent(status: nil, notices: lingeringNotices)
  }

  /// 進行中のセッションの通知。録音停止の通知、退避の通知の順に並べる。
  private var activeNotices: [HUDNotice] {
    var notices: [HUDNotice] = []
    if let notice = stopReason.flatMap(HUDNotice.init(stopReason:)) {
      notices.append(notice)
    }
    if let refinementFallback {
      notices.append(.refinementFellBack(refinementFallback))
    }
    return notices
  }

  private mutating func clearLingeringNotice() {
    lingeringNotices = []
    noticeExpiry = nil
  }
}
