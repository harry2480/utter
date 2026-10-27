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
  /// 失敗の表示に添える理由。失敗の表示中だけ持つ
  private var failureNotice: HUDNotice?
  /// 進行中のセッションがローカル整形へ退避した理由
  private var refinementFallback: RefinementFallbackNotice?
  /// 進行中のセッションで Realtime Direct を自動で無効にした理由（AC-15）
  private var realtimeDirectFallback: RealtimeDirectFallbackNotice?
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
  /// 挿入中から待機に戻ったとき（正常完了）だけ、上限到達・退避の通知を `limitNoticeDisplayDuration` だけ残す。
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
      let notices = activeNotices
      if previousPhase == .inserting, !notices.isEmpty {
        lingeringNotices = notices
        noticeExpiry = now.advanced(by: configuration.limitNoticeDisplayDuration)
      } else if previousPhase != .idle {
        clearLingeringNotice()
      }
      sessionID = nil
      stopReason = nil
      self.failureNotice = nil
      refinementFallback = nil
      realtimeDirectFallback = nil
      errorDismissDeadline = nil
      return
    }

    let isNewSession = activeSession.id != sessionID
    if isNewSession {
      clearLingeringNotice()
      sessionID = activeSession.id
      refinementFallback = nil
      realtimeDirectFallback = nil
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

  /// 進行中のセッションで Realtime Direct を自動で無効にしたことを反映する（2.2節, AC-15）。
  ///
  /// 録音中〜挿入中に、反映済みのセッション（`update(from:at:)` で渡したもの）について呼ぶ。待機中・失敗の表示中、
  /// 反映済みのセッションと異なるセッションでは無視する。同じセッションで複数回呼んだ場合は最後の理由を表示する。
  /// 退避の通知と同じく、挿入を終えて待機に戻った後もしばらく残す
  public mutating func recordRealtimeDirectFallback(
    _ notice: RealtimeDirectFallbackNotice, for sessionID: SessionID
  ) {
    switch phase {
    case .recording, .recognizing, .refining, .inserting: break
    case .idle, .error: return
    }
    guard sessionID == self.sessionID else { return }
    realtimeDirectFallback = notice
  }

  /// 機密入力の判定で録音を始めなかったことを知らせる（7章, AC-12）。
  ///
  /// セッションを始めないため、待機中に呼ぶ。上限到達・退避の通知と同じく `limitNoticeDisplayDuration` だけ残し、
  /// 前に残していた通知は置き換える。待機中でなければ（録音中〜失敗の表示中）無視する
  public mutating func recordRecordingSuppressed(
    _ reason: SensitiveInputReason, at now: ContinuousClock.Instant
  ) {
    guard phase == .idle else { return }
    lingeringNotices = [.recordingSuppressed(reason)]
    noticeExpiry = now.advanced(by: configuration.limitNoticeDisplayDuration)
  }

  /// `now` の時点で HUD に表示する内容。何も表示しないときは `nil`。
  public func content(at now: ContinuousClock.Instant) -> HUDContent? {
    if let status = HUDStatus(phase: phase) {
      return HUDContent(status: status, notices: activeNotices)
    }
    guard !lingeringNotices.isEmpty, let noticeExpiry, now < noticeExpiry else { return nil }
    return HUDContent(status: nil, notices: lingeringNotices)
  }

  /// 進行中のセッションの通知。録音停止の通知（失敗の表示中に失敗の理由があればそれに置き換える）、
  /// Realtime Direct を無効にした通知、退避の通知の順に並べる。
  private var activeNotices: [HUDNotice] {
    var notices: [HUDNotice] = []
    if let notice = failureNotice ?? stopReason.flatMap(HUDNotice.init(stopReason:)) {
      notices.append(notice)
    }
    if let realtimeDirectFallback {
      notices.append(.realtimeDirectDisabled(realtimeDirectFallback))
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
