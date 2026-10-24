/// HUD の表示・非表示・内容の更新を受け持つ画面側の実装（REC-03）。Apps が OS の画面部品で実装する。
@MainActor
public protocol HUDPresenting: AnyObject {
  /// 表示する（表示中なら内容を差し替える）。フォーカスを奪ってはならない
  func show(_ presentation: HUDPresentation)
  /// 隠す。表示していなければ何もしない
  func hide()
}

/// 指定した時刻に HUD の表示を更新するための予約。Apps がタイマーで実装し、テストは Stub で時刻を進める。
@MainActor
public protocol HUDRefreshScheduling: AnyObject {
  /// `deadline` に `action` を1回呼ぶよう予約する。前の予約は取り消す。`deadline` が `nil` なら取り消すだけ。
  func schedule(at deadline: ContinuousClock.Instant?, _ action: @escaping @MainActor () -> Void)
}

/// `HUDState` を保持し、状態の変化と表示時間の経過に合わせて HUD を更新する（REC-03, REC-05）。
///
/// セッションを進める側は状態機械を変えるたびに `update(from:)` を呼ぶ。表示する内容が変わったときだけ
/// `HUDPresenting` に表示・非表示を依頼し、通知を消す時刻と失敗の表示を終える時刻に `HUDRefreshScheduling` で更新を予約する。
/// 失敗の表示時間が過ぎたら `onErrorDisplayExpired` を1回呼ぶ。受け取った側は
/// `SessionStateMachine.dismissError()` を呼んで `update(from:)` で反映する（反映するまで失敗を表示し続ける）。
@MainActor
public final class HUDController {
  public private(set) var state: HUDState
  /// 表示中の内容。表示していなければ `nil`
  public private(set) var presentation: HUDPresentation?
  /// 失敗の表示時間が過ぎたときに呼ぶ
  public var onErrorDisplayExpired: (@MainActor () -> Void)?

  private let presenter: any HUDPresenting
  private let scheduler: any HUDRefreshScheduling
  private let now: @MainActor () -> ContinuousClock.Instant
  /// `onErrorDisplayExpired` を呼び終えた失敗の表示期限
  private var expiredErrorDeadline: ContinuousClock.Instant?

  /// - Parameters:
  ///   - now: 現在時刻。テストでは固定・手動で進める時刻を渡す
  public init(
    configuration: HUDConfiguration = HUDConfiguration(),
    presenter: any HUDPresenting,
    scheduler: any HUDRefreshScheduling,
    now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    state = HUDState(configuration: configuration)
    self.presenter = presenter
    self.scheduler = scheduler
    self.now = now
  }

  /// 状態機械の現在の状態を反映する。
  /// - Parameter failureNotice: 失敗の表示に添える理由（`HUDState.update(phase:activeSession:failureNotice:at:)`）
  public func update(from machine: SessionStateMachine, failureNotice: HUDNotice? = nil) {
    update(
      phase: machine.phase, activeSession: machine.activeSession, failureNotice: failureNotice)
  }

  /// セッションの状態を反映する。状態が変わるたびに呼ぶ（同じ状態で何度呼んでもよい）。
  public func update(
    phase: SessionPhase, activeSession: ActiveSession?, failureNotice: HUDNotice? = nil
  ) {
    state.update(
      phase: phase, activeSession: activeSession, failureNotice: failureNotice, at: now())
    refresh()
  }

  private func refresh() {
    let now = now()
    let next = state.content(at: now).flatMap(HUDPresentation.init)
    if next != presentation {
      presentation = next
      if let next {
        presenter.show(next)
      } else {
        presenter.hide()
      }
    }

    var deadlines: [ContinuousClock.Instant] = []
    var errorDisplayExpired = false
    if let errorDeadline = state.errorDismissDeadline {
      if errorDeadline > now {
        deadlines.append(errorDeadline)
      } else if errorDeadline != expiredErrorDeadline {
        expiredErrorDeadline = errorDeadline
        errorDisplayExpired = true
      }
    } else {
      expiredErrorDeadline = nil
    }
    if presentation != nil, let noticeExpiry = state.noticeExpiry, noticeExpiry > now {
      deadlines.append(noticeExpiry)
    }
    scheduler.schedule(at: deadlines.min()) { [weak self] in
      self?.refresh()
    }

    // 呼び出し先が同期的に update(from:) を呼んでもよいよう、予約を済ませてから最後に呼ぶ
    if errorDisplayExpired {
      onErrorDisplayExpired?()
    }
  }
}
