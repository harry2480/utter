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
/// セッションを進める側は状態機械を変えるたびに `update(from:)` を呼び、ローカル整形へ退避したら
/// `recordRefinementFallback(_:for:)` を呼ぶ。機密入力の判定で録音を始めなかったら `recordRecordingSuppressed(_:)` を呼ぶ。表示する内容が変わったときだけ
/// `HUDPresenting` に表示・非表示を依頼し、通知を消す時刻と失敗の表示を終える時刻に `HUDRefreshScheduling` で更新を予約する。
/// 失敗の表示時間が過ぎたら `onErrorDisplayExpired` を1回呼ぶ。受け取った側は
/// `SessionStateMachine.dismissError()` を呼んで `update(from:)` で反映する（反映するまで失敗を表示し続ける）。
///
/// 入力モードが Realtime Preview なら、認識のイベントのたびに `updateTranscript(_:for:)` で認識テキストを渡す（2.2節, AC-03）。
/// 認識テキストは渡したセッションの録音中・認識中だけ表示し、別のセッションになるか他の段階へ進んだら捨てる。
///
/// 状態と通知のほかに、次を表示に添える（REC-03, REC-05）。セッションごとの値は渡したセッションの間だけ使い、別のセッションでは捨てる。
/// - 録音の経過時間と最大録音時間。録音中は1秒の区切りごとに `HUDRefreshScheduling` で更新を予約する
/// - 録音開始時のセッションの設定（`recordSessionDetails(_:for:)`。整形モード・アプリ別スタイル・音声認識の種別）
/// - 録音中の入力音量（`updateInputLevel(_:for:)`。点灯する本数が変わったときだけ表示を更新する）
/// - クラウド整形の送信先（`recordRefinementDestination(_:for:)`。整形中だけ）
/// - 停止・キャンセルのキー（`updateKeyHints(_:)`。セッションによらない）
/// - 挿入先のアプリ名（`recordInsertion(_:for:)`。挿入を終えた後にしばらく残す）
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
  /// 表示中のセッション
  private var sessionID: SessionID?
  /// 認識テキストを表示する段階（録音中・認識中）か
  private var showsTranscript = false
  /// 表示中のセッションの Realtime Preview の認識テキスト
  private var transcript: HUDTranscript?
  /// 反映済みの状態
  private var phase: SessionPhase = .idle
  /// 録音開始時に知らされたセッションの設定。表示中のセッションと同じときだけ使う
  private var details: (session: SessionID, details: HUDSessionDetails)?
  /// 表示中のセッションの録音中の入力音量
  private var inputLevel: HUDInputLevel?
  /// 表示中のセッションのクラウド整形の送信先
  private var refinementDestination: CloudAIProviderKind?
  /// 停止・キャンセルのキー
  private var keyHints = HUDKeyHints()

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
      phase: machine.phase, activeSession: machine.activeSession, failureNotice: failureNotice,
      maxRecordingDuration: machine.configuration.maxRecordingDuration)
  }

  /// セッションの状態を反映する。状態が変わるたびに呼ぶ（同じ状態で何度呼んでもよい）。
  /// - Parameter maxRecordingDuration: 最大録音時間。録音中の経過時間に添える（`update(from:)` は状態機械の値を渡す）
  public func update(
    phase: SessionPhase, activeSession: ActiveSession?, failureNotice: HUDNotice? = nil,
    maxRecordingDuration: Duration? = nil
  ) {
    state.update(
      phase: phase, activeSession: activeSession, failureNotice: failureNotice,
      maxRecordingDuration: maxRecordingDuration, at: now())
    // 前のセッションの発話と、録音中・認識中を過ぎた後の認識テキストを残さない
    showsTranscript = phase == .recording || phase == .recognizing
    let isOtherSession = activeSession?.id != sessionID
    if isOtherSession || !showsTranscript {
      transcript = nil
    }
    if isOtherSession || phase != .recording {
      inputLevel = nil
    }
    if isOtherSession || phase != .refining {
      refinementDestination = nil
    }
    self.phase = phase
    sessionID = activeSession?.id
    refresh()
  }

  /// Realtime Preview の認識テキストを反映する（2.2節, AC-03）。
  ///
  /// `session` が表示中のセッションでなければ（キャンセル済み・別のセッション）、録音中・認識中でなければ何もしない。
  /// 入力モードが Instant なら呼ばない。
  public func updateTranscript(_ transcript: HUDTranscript?, for session: SessionID) {
    guard session == sessionID, showsTranscript else { return }
    self.transcript = transcript
    refresh()
  }

  /// 進行中のセッションがローカル整形へ退避したことを反映する（4.1節, AC-16）。
  ///
  /// 整形の結果を受け取ったら、状態機械へ整形完了を知らせる前（整形中を `update(from:)` で反映した状態）に呼ぶ。
  /// 条件は `HUDState.recordRefinementFallback(_:for:)` を参照
  public func recordRefinementFallback(_ notice: RefinementFallbackNotice, for session: SessionID) {
    state.recordRefinementFallback(notice, for: session)
    refresh()
  }

  /// 進行中のセッションで Realtime Direct を自動で無効にしたことを反映する（2.2節, AC-15）。
  ///
  /// 条件は `HUDState.recordRealtimeDirectFallback(_:for:)` を参照
  public func recordRealtimeDirectFallback(
    _ notice: RealtimeDirectFallbackNotice, for session: SessionID
  ) {
    state.recordRealtimeDirectFallback(notice, for: session)
    refresh()
  }

  /// 機密入力の判定で録音を始めなかったことを知らせる（7章, AC-12）。
  ///
  /// 条件は `HUDState.recordRecordingSuppressed(_:at:)` を参照
  public func recordRecordingSuppressed(_ reason: SensitiveInputReason) {
    state.recordRecordingSuppressed(reason, at: now())
    refresh()
  }

  /// 録音開始時のセッションの設定を知らせる（REC-03）。録音中のチップに出す。
  ///
  /// 状態機械でセッションを始めた直後に呼ぶ。`update(from:)` で反映する前に呼んでもよい（反映したときから使う）。
  /// 別のセッションを反映したら捨てる
  public func recordSessionDetails(_ details: HUDSessionDetails, for session: SessionID) {
    self.details = (session, details)
    refresh()
  }

  /// 録音中の入力音量を反映する（REC-03）。録音のチャンクが届くたびに呼ぶ。
  ///
  /// `session` が表示中のセッションでなければ、録音中でなければ何もしない。点灯する本数が変わったときだけ表示を更新する
  public func updateInputLevel(_ level: HUDInputLevel, for session: SessionID) {
    guard session == sessionID, phase == .recording, level != inputLevel else { return }
    inputLevel = level
    refresh()
  }

  /// 整形中のセッションがクラウドへ送ると決めたことを知らせる（REC-03, AC-06）。
  ///
  /// 送る直前に呼ぶ。整形中でないとき、表示中のセッションでなければ何もしない。整形中を過ぎたら出さない
  public func recordRefinementDestination(
    _ destination: CloudAIProviderKind, for session: SessionID
  ) {
    guard session == sessionID, phase == .refining else { return }
    refinementDestination = destination
    refresh()
  }

  /// 停止・キャンセルに使えるキーを反映する（REC-01, REC-02）。ショートカットの登録・Esc の捕捉の状態が変わるたびに呼ぶ
  public func updateKeyHints(_ hints: HUDKeyHints) {
    guard hints != keyHints else { return }
    keyHints = hints
    refresh()
  }

  /// 挿入中のセッションの挿入先を知らせる（REC-03）。
  ///
  /// 条件は `HUDState.recordInsertion(_:for:)` を参照
  public func recordInsertion(_ insertion: HUDInsertion, for session: SessionID) {
    state.recordInsertion(insertion, for: session)
    refresh()
  }

  /// 表示中のセッションについて、状態以外に表示に添える情報
  private func sessionInfo(at now: ContinuousClock.Instant) -> HUDSessionInfo {
    let currentDetails = details.flatMap { $0.session == sessionID ? $0.details : nil }
    return HUDSessionInfo(
      details: currentDetails,
      recordingTime: state.recordingTime(at: now),
      inputLevel: inputLevel,
      refinementDestination: refinementDestination,
      keyHints: keyHints)
  }

  private func refresh() {
    let now = now()
    let info = sessionInfo(at: now)
    let next = state.content(at: now).flatMap {
      HUDPresentation($0, transcript: transcript, info: info)
    }
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
    // 録音中は経過時間を1秒ごとに進める
    if presentation != nil, let tick = state.nextRecordingTimeUpdate(after: now) {
      deadlines.append(tick)
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
