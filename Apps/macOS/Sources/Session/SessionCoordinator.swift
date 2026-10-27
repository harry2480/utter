import Observation
import UtterAI
import UtterCore
import UtterSpeech
import UtterText

/// 録音 → 音声認識 → 整形 → 挿入 → HUD を1つのセッションとして進める調停役（REC-01〜06, INS-01, AC-02, AC-09）。
///
/// 状態は `SessionStateMachine` が持ち、ここは操作・非同期処理の結果を状態機械へ渡して、HUD と各部品を動かすだけにする。
/// 非同期処理は依頼したセッションを覚えておき、状態機械のセッションと違えば（キャンセル済み・別のセッション）結果を捨てる。
///
/// - 音声認識のエンジンが選ばれていない（`recognizer == nil`）なら、マイクを開かずに「音声認識が設定されていません」の失敗を表示する
/// - 録音開始時に入力対象（とスタイル区分の判定に使う前面アプリ）を記録し、挿入はその対象に対して確かめる（INS-01）
/// - 整形は `SessionRefining`（本番は `SessionRefinementPipeline`）に任せる。設定・同意・API キー・予算がそろい、
///   入力先が機密入力でないときだけクラウドへ送り、それ以外はローカル整形（Raw / Local Basic, AI-03）にする
/// - 挿入を終えたら、履歴が有効で機密入力でないときだけ入力履歴に保存する（7章, AC-12）
/// - クラウドへ送ろうとしてローカル整形へ退避したら、HUD で退避の理由を知らせる（4.1節, AC-16）
/// - 最大録音時間・音声バッファの上限・割り込みで録音を止めたら、それまでの音声を処理して HUD で知らせる（REC-05, iOS-PERF-03）
/// - キャンセルは録音〜整形中と失敗の表示中だけ受け付ける。挿入が始まったら取り消さない（REC-01）
/// - 処理中の開始操作は無視する（REC-06）
/// - 入力モードが Realtime Preview なら、認識の `partial` / `confirmed` を `TranscriptPreview` に溜めて HUD に出す（2.2節, AC-03）。
///   Instant（既定）と Realtime Direct では出さない。Instant と Realtime Preview の入力欄への挿入は停止後に一括で行う
/// - 最大録音時間と入力モードは、`useSettings(_:)` で渡した値を次のセッションの開始時から使う。録音中・処理中のセッションは変えない
/// - 発話本文はログに出さない。HUD に出すのは Realtime Preview の録音中・認識中の認識テキストだけ。
///   挿入できなければ挿入側がコピー可能なプレビューへ退避する（AC-09）
/// - 録音のチャンクは一時音声の差し込み口にも渡す。STT Worker の異常終了で認識が失敗したら、録音が止まるのを待って
///   メモリ上の録音全体で1回だけ認識し直す（7章, AC-10）
/// - 状態が変わるたびに `onPhaseChange` を呼ぶ（ショートカットの Esc の捕捉をセッション中だけ有効にするため, REC-01）
/// - クラウド STT（#188, MVP 外）を選んでいれば、STT Worker を通さずにクラウド STT で認識する。使うかはセッションの開始時に決め、
///   録音を始める前に同意・API キー・予算を確かめる。そろわなければマイクを開かずに理由を HUD に出す。
///   クラウド STT の失敗では認識し直さない（Worker の異常終了の再処理は STT Worker のときだけ）
/// - 入力モードが Realtime Direct（実験機能・MVP 外, AC-15）なら、録音開始時に `SessionRealtimeDirectWriting` で使えるか確かめ、
///   録音中の認識イベントを渡して確定済みチャンクを入力欄へ逐次書き込む（整形はしない）。許可リストにないアプリ・機密入力・
///   クラウド STT では自動で無効にして HUD で知らせ、Instant と同じく停止後に整形して一括挿入する。書き込む前の照合に
///   失敗した場合も同じ。書き込んだ後に照合に失敗したら、書き込みを残して全体をプレビューに出す（書き込み側が出す）。
///   キャンセルでは書き込んだ範囲を照合のうえ取り除き、完了後は `undoRealtimeDirect()` で取り除ける。
///   Realtime Direct のセッションでは、STT Worker の異常終了で認識し直さない（書き込んだ範囲と食い違うため）
@MainActor
@Observable
final class SessionCoordinator {
  /// セッションの現在の状態。メニューの表示に使う
  private(set) var phase: SessionPhase = .idle
  /// 状態が変わるたびに呼ぶ。Esc のイベントタップのコールバックの中からも同期的に呼ばれるため、重い処理をしない
  @ObservationIgnored var onPhaseChange: (@MainActor () -> Void)?
  /// 直前の Realtime Direct のセッションで書き込んだテキストを取り除けるか（AC-15）。メニューの表示に使う
  private(set) var canUndoRealtimeDirect = false

  @ObservationIgnored private var machine: SessionStateMachine
  @ObservationIgnored private let recorder: any AudioRecorder
  @ObservationIgnored private let recognizer: (any SpeechRecognizer)?
  @ObservationIgnored private let refiner: any SessionRefining
  @ObservationIgnored private let refinementReporter: (any SessionRefinementReporting)?
  /// 進行中のセッションの入力モード。セッションの開始時に `nextSettings` から決める
  @ObservationIgnored private var inputMode: SessionInputMode
  /// 次のセッションから使う設定（`useSettings(_:)`）
  @ObservationIgnored private var nextSettings: SessionSettings
  @ObservationIgnored private let makeSessionID: @Sendable () -> SessionID
  @ObservationIgnored private let inserter: any SessionTextInserting
  @ObservationIgnored private let history: (any SessionHistoryRecording)?
  @ObservationIgnored private let hud: HUDController
  @ObservationIgnored private let deadlineScheduler: any SessionDeadlineScheduling
  @ObservationIgnored private let interruptionPolicy: RecordingInterruptionPolicy
  @ObservationIgnored private let audioRetention: (any SessionAudioRetaining)?
  @ObservationIgnored private let recognitionRecovery: (any SessionRecognitionRecovering)?
  @ObservationIgnored private let cloudRecognition: (any SessionCloudSpeechRecognizing)?
  @ObservationIgnored private let realtimeDirect: (any SessionRealtimeDirectWriting)?
  @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

  /// 進行中のセッションの非同期処理
  @ObservationIgnored private var runTask: Task<Void, Never>?
  /// 一時音声の差し込み口に `begin` を伝えて、まだ `end` を伝えていないセッション
  @ObservationIgnored private var retainedSession: SessionID?
  /// 録音の停止を順に行うためのタスク。次の録音はこれを待ってから始める（REC-04 の連打）
  @ObservationIgnored private var recorderStop: Task<Void, Never>?

  /// - Parameters:
  ///   - recognizer: 音声認識。エンジンが選ばれていなければ `nil`（Phase 0 の判定待ちで既定のエンジンを持たない）
  ///   - refiner: 整形（TXT-01, AI-01, AI-03）。録音開始時の前面アプリをスタイル区分の判定に渡す（CTX-01）
  ///   - refinementReporter: 整形の経路を知らせる差し込み口（AC-16）。退避の HUD 通知はこれによらず `hud` に出す
  ///   - configuration: 起動時の最大録音時間など（REC-05）。設定画面の変更は `useSettings(_:)` で渡す
  ///   - inputMode: 起動時の入力モード（2.2節）。既定は Instant（MVP 標準）
  ///   - history: 入力履歴への保存（7章, AC-12）。`nil` なら保存しない
  ///   - audioRetention: 一時音声の保存の差し込み口（7章, AC-10）。`nil` なら保存しない
  ///   - recognitionRecovery: 失敗した認識を録音音声でやり直すかの判断（7章, AC-10）。`nil`、または `audioRetention` が
  ///     `nil` ならやり直さない。クラウド STT のセッションでは使わない
  ///   - cloudRecognition: クラウド STT（#188）。`nil`、または選んでいなければ `recognizer` を使う
  ///   - realtimeDirect: Realtime Direct の書き込み（AC-15）。`nil` なら入力モードが Realtime Direct でも使えない扱いにする
  ///   - now: 現在時刻。テストでは手動で進める時刻を渡す
  init(
    configuration: SessionConfiguration = SessionConfiguration(),
    recorder: any AudioRecorder,
    recognizer: (any SpeechRecognizer)?,
    refiner: any SessionRefining,
    refinementReporter: (any SessionRefinementReporting)? = nil,
    inputMode: SessionInputMode = .instant,
    inserter: any SessionTextInserting,
    history: (any SessionHistoryRecording)? = nil,
    hud: HUDController,
    deadlineScheduler: any SessionDeadlineScheduling,
    interruptionPolicy: RecordingInterruptionPolicy = RecordingInterruptionPolicy(),
    audioRetention: (any SessionAudioRetaining)? = nil,
    recognitionRecovery: (any SessionRecognitionRecovering)? = nil,
    cloudRecognition: (any SessionCloudSpeechRecognizing)? = nil,
    realtimeDirect: (any SessionRealtimeDirectWriting)? = nil,
    makeSessionID: @escaping @Sendable () -> SessionID = { SessionID() },
    now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    machine = SessionStateMachine(configuration: configuration, makeSessionID: makeSessionID)
    self.recorder = recorder
    self.recognizer = recognizer
    self.refiner = refiner
    self.refinementReporter = refinementReporter
    self.inputMode = inputMode
    nextSettings = SessionSettings(configuration: configuration, inputMode: inputMode)
    self.makeSessionID = makeSessionID
    self.inserter = inserter
    self.history = history
    self.hud = hud
    self.deadlineScheduler = deadlineScheduler
    self.interruptionPolicy = interruptionPolicy
    self.audioRetention = audioRetention
    self.recognitionRecovery = audioRetention == nil ? nil : recognitionRecovery
    self.cloudRecognition = cloudRecognition
    self.realtimeDirect = realtimeDirect
    self.now = now
    hud.onErrorDisplayExpired = { [weak self] in
      guard let self else { return }
      machine.dismissError()
      reflect()
    }
  }

  /// 新しいセッションを始めないよう止めているか（起動時の復旧中, 7章, AC-10）
  @ObservationIgnored private(set) var isSuspended = false

  /// 待機中なら、`resume()` まで新しいセッションを始めないようにして `true` を返す。待機中でなければ何もせず `false`。
  ///
  /// STT Worker は同時に1セッションしか認識しないため、起動時の復旧が認識し直す間に録音を始めると、
  /// その録音が `resourceLimited` で失敗して発話を失う。それを防ぐために、復旧の確認と認識の間は開始操作を無視する
  func suspendIfIdle() -> Bool {
    guard machine.phase == .idle, !isSuspended else { return false }
    isSuspended = true
    return true
  }

  /// `suspendIfIdle()` で止めた開始操作を受け付け直す
  func resume() {
    isSuspended = false
  }

  /// 設定画面で保存した最大録音時間と入力モードを、次のセッションの開始時から使う（REC-05, 2.2節）。
  ///
  /// 録音中・処理中のセッションの最大録音時間のタイマー・音声バッファ・HUD の表示は変えない
  func useSettings(_ settings: SessionSettings) {
    nextSettings = settings
  }

  /// 進行中のセッション。テストと表示の確認に使う
  var activeSession: ActiveSession? {
    machine.activeSession
  }

  /// キャンセルを受け付ける状態か（録音〜整形中と失敗の表示中, REC-01）
  var canCancel: Bool {
    switch phase {
    case .recording, .recognizing, .refining, .error: true
    case .idle, .inserting: false
    }
  }

  // MARK: - 操作

  /// ショートカットの操作を実行する（REC-01, REC-02）
  func perform(_ command: ShortcutCommand) {
    switch command {
    case .startRecording: startRecording()
    case .stopRecording: stopRecording()
    case .cancelSession: cancel()
    }
  }

  /// 待機中なら録音を始め、録音中なら止める（メニューの操作）。それ以外は無視する（REC-06）
  func toggle() {
    switch machine.phase {
    case .idle: startRecording()
    case .recording: stopRecording()
    case .recognizing, .refining, .inserting, .error: break
    }
  }

  /// 録音を始める。待機中でなければ何もしない（処理中の開始操作は無視する, REC-06）。
  /// 起動時の復旧が音声認識を使っている間（`suspendIfIdle()` から `resume()` まで）も無視する
  func startRecording() {
    guard machine.phase == .idle, !isSuspended else { return }
    applyNextSettings()
    // クラウド STT を使うかはセッションの開始時に決め、このセッションの間は変えない（設定の変更は次のセッションから）
    let usesCloud = cloudRecognition?.isSelected == true
    guard usesCloud || recognizer != nil else {
      failWithoutRecording(notice: .speechRecognitionNotConfigured)
      return
    }
    guard case .started(let token) = machine.start(at: now()) else { return }
    let session = token.sessionID
    // 入力対象は録音開始時に記録する（INS-01）
    let target = inserter.recordTarget()
    retainedSession = session
    audioRetention?.begin(session)
    // 前のセッションの書き込みは、次のセッションを始めたら取り消せない（入力欄の状態を確かめ直せないため）
    canUndoRealtimeDirect = false
    reflect()
    // 入力対象を記録した直後に、同じ入力欄で Realtime Direct を使えるか確かめる
    let writesDirectly = beginRealtimeDirect(session, target: target, usesCloud: usesCloud)
    runTask = Task { [weak self] in
      await self?.run(
        session: session, target: target, usesCloud: usesCloud, writesDirectly: writesDirectly)
    }
  }

  /// 録音を止めて認識へ進む。録音中でなければ何もしない
  func stopRecording() {
    guard machine.stopRecording(at: now()) != nil else { return }
    reflect()
    stopRecorder()
  }

  /// 進行中のセッションを破棄して待機に戻る。挿入中と待機中は何もしない（REC-01）
  func cancel() {
    guard let session = machine.cancel() else { return }
    runTask?.cancel()
    runTask = nil
    // Realtime Direct で書き込んだテキストを照合のうえ取り除く（別のセッションなら何もしない, AC-15）
    realtimeDirect?.cancel(session)
    stopRecorder()
    endRetention(session, completed: false)
    reflect()
  }

  // MARK: - セッションの処理

  private func run(
    session: SessionID, target: RecordedInsertionTarget, usesCloud: Bool, writesDirectly: Bool
  ) async {
    // 前の録音の停止が終わってから始める（連打で2つ目の録音を始めない, REC-04）
    await recorderStop?.value
    guard isActive(session) else { return }
    guard machine.phase == .recording else {
      // 録音を始める前に停止された。音声がないため何も処理せずに待機へ戻る
      abandon(session)
      return
    }
    guard let recognizer = await sessionRecognizer(session, usesCloud: usesCloud) else { return }
    // STT Worker の異常終了の再処理は、Worker のときだけ使う。クラウド STT は Worker を通さず、
    // 失敗は通信・同意・予算などで同じ音声を送り直しても直らない（送り直すと費用もかかる）ため。
    // Realtime Direct は、認識し直した全体と書き込んだ範囲を突き合わせられないため使わない
    let recovery = usesCloud || writesDirectly ? nil : self.recognitionRecovery

    let recording: AudioRecording
    do {
      recording = try await startRecorder()
    } catch {
      guard isActive(session) else { return }
      switch error {
      case .cancelled:
        // マイクの使用許可を待つ間に停止された。音声がないため何も処理せずに待機へ戻る
        abandon(session)
      case .microphoneAccessDenied, .microphoneAccessRestricted:
        fail(session, notice: .microphoneAccessDenied)
      case .alreadyRecording, .inputDeviceUnavailable, .startFailed:
        fail(session, notice: nil)
      }
      return
    }
    guard isActive(session) else {
      // 開始を待つ間にキャンセルされた
      stopRecorder()
      return
    }
    guard machine.phase == .recording else {
      // 開始を待つ間（マイクの使用許可を待つ間など）に停止された。録音は今始まったばかりで音声がないため、
      // 停止の届き方（開始の前か後か）によらず、何も処理せずに待機へ戻る
      stopRecorder()
      abandon(session)
      return
    }

    let ends = Task { [weak self] in
      for await end in recording.ends {
        self?.recordingEnded(end, session: session)
      }
    }
    defer { ends.cancel() }

    let forwarding = forward(
      recording.chunks, session: session, keepsReading: recovery != nil)
    var text: String?
    var failure: SpeechRecognitionError?
    var completed = false
    // 別のセッション・順序の古いイベントは捨てる（認識の契約の SessionID と順序番号で確かめる）
    var filter = RecognitionEventFilter()
    filter.begin(session)
    // Realtime Preview の確定済み・暫定テキスト。セッションごとに作り直し、前の発話を残さない
    var preview = TranscriptPreview()
    for await event in recognizer.recognize(forwarding.audio, session: session) {
      guard isActive(session) else { return }
      guard filter.accept(event) == nil else { continue }
      // Realtime Direct では、確定済みチャンクと終端のイベントで入力欄へ書き込む（暫定の結果は書き込まない）
      if writesDirectly { realtimeDirect?.handle(event) }
      switch event.kind {
      case .partial, .confirmed:
        if inputMode == .realtimePreview {
          preview.apply(event.kind)
          hud.updateTranscript(
            HUDTranscript(
              confirmedText: preview.confirmedText, provisionalText: preview.provisionalText),
            for: session)
        }
        continue
      case .completed(let value):
        text = value
        completed = true
      case .failed(let error):
        failure = error
        completed = true
      }
      if completed { break }
    }
    guard isActive(session) else { return }

    // STT Worker の異常終了で失敗したら、録音音声で認識し直す（7章, AC-10）
    var recognizesAgain = false
    if text == nil, let failure, let recovery {
      recognizesAgain = await recovery.shouldRecognizeAgain(session, after: failure)
      guard isActive(session) else { return }
    }

    // 録音の終わり（割り込み・上限到達）を状態機械へ反映してから認識の結果を渡す
    if machine.phase == .recording {
      if recognizesAgain {
        // 録音中に失敗した。発話を途中で切らないよう、録音は止めずに利用者の停止（または上限）を待つ
        await forwarding.task.value
      } else {
        await stopRecorder().value
      }
      await ends.value
      guard isActive(session) else { return }
      if machine.phase == .recording {
        machine.stopRecording(at: now())
        reflect()
      }
    }
    guard machine.phase == .recognizing else { return }
    if recognizesAgain {
      text = await recognizeAgain(session, forwarding: forwarding.task, recognizer: recognizer)
      guard isActive(session), machine.phase == .recognizing else { return }
    }
    guard let text else {
      // 失敗、または終端イベントのないまま認識が終わった。クラウド STT の失敗は理由を出す（#188）
      let reason = usesCloud ? failure.flatMap { CloudSpeechRecognitionNotice($0) } : nil
      fail(session, notice: reason.map { HUDNotice.cloudSpeechRecognitionFailed($0) })
      return
    }
    // Realtime Direct で書き込んだら、整形・一括挿入をしない。何も書き込まないうちにやめたら Instant と同じく続ける
    let directCompletion = writesDirectly ? realtimeDirect?.completion : nil
    if case .stoppedBeforeWriting = directCompletion {
      hud.recordRealtimeDirectFallback(.stoppedBeforeWriting, for: session)
    }
    guard apply(.recognitionCompleted, session: session) else { return }
    switch directCompletion {
    case .finished, .stoppedAfterWriting:
      await finishRealtimeDirect(
        session, text: text, completion: directCompletion, target: target,
        forwarding: forwarding.task)
      return
    case .stoppedBeforeWriting, nil:
      break
    }

    // 整形。クラウドへ送るかは整形側が設定・同意・API キー・予算・入力先で決め、送れなければローカル整形にする
    let inserter = inserter
    let sensitivity: @MainActor @Sendable () -> SensitiveInputContext = {
      inserter.sensitiveInputContext(for: target)
    }
    let refined: SessionRefinementResult
    do throws(CancellationError) {
      refined = try await refiner.refine(
        text, frontmostApp: target.app, sensitivity: sensitivity)
    } catch {
      return
    }
    guard isActive(session) else { return }
    refinementReporter?.refinementFinished(refined.route, session: session)
    // 送ろうとしてローカル整形へ退避したら HUD で知らせる（4.1節, AC-16）。HUD は整形中を反映している間だけ受け付けるため、
    // 整形完了を状態機械へ渡す前に知らせる。送らなかった場合（`localOnly`）は知らせない
    if case .cloudFallback(let reason) = refined.route {
      hud.recordRefinementFallback(RefinementFallbackNotice(reason: reason), for: session)
    }
    guard apply(.refinementCompleted, session: session) else { return }

    // 挿入。自動挿入できなければ挿入側がプレビューへ退避する（文字列を失わない, AC-09）。
    // 挿入は始まったら取り消さないため、退避した場合も完了として待機へ戻る
    let report = await inserter.insert(refined.text, into: target)
    guard apply(.insertionCompleted, session: session) else { return }
    // 待機に戻ったため、以降に次のセッションが始まりうる。次のセッションのタスクを消さないよう先に外す
    runTask = nil
    // 入力先へ挿入したときだけ履歴に保存する（プレビューへの退避・空の本文は保存しない）
    if case .finished = report.outcome {
      await history?.record(refined.text, session: session, sensitivity: sensitivity)
    }
    // 録音のチャンクをすべて差し込み口に渡し終えてから終わりを伝える
    await forwarding.task.value
    endRetention(session, completed: true)
  }

  // MARK: - Realtime Direct

  /// 直前の Realtime Direct のセッションで書き込んだテキストを、照合のうえ取り除く（AC-15）。
  ///
  /// 待機中で、直前のセッションが全体を書き込んで終えたときだけ行う（一度だけ）。フォーカスが一時的に別の入力欄にあるだけなら、
  /// 入力欄に触れずに `unavailable` を返し、戻ってから取り消せるようにする。行わなければ `nil`
  @discardableResult
  func undoRealtimeDirect() -> RealtimeDirectUndoOutcome? {
    guard machine.phase == .idle, canUndoRealtimeDirect, let realtimeDirect else { return nil }
    let outcome = realtimeDirect.undo()
    switch outcome {
    case .unavailable(.targetChanged), .unavailable(.targetMissing):
      break
    case .reverted, .nothingToRevert, .unavailable, .writeFailed, .noSession:
      canUndoRealtimeDirect = false
    }
    return outcome
  }

  /// 入力モードが Realtime Direct なら、録音開始時の入力対象で使えるか確かめて始める。使えなければ理由を HUD に出す。
  /// 始めたら `true`。状態機械を録音へ進めて HUD に反映した後に呼ぶ
  private func beginRealtimeDirect(
    _ session: SessionID, target: RecordedInsertionTarget, usesCloud: Bool
  ) -> Bool {
    guard inputMode == .realtimeDirect else { return false }
    let notice: RealtimeDirectFallbackNotice
    if usesCloud {
      // クラウド STT は一括認識で、録音中に確定済みチャンクを流さない（#188）
      notice = .cloudSpeechRecognition
    } else if let realtimeDirect {
      // 入力モードで Realtime Direct を選んだことを、実験機能の有効化とみなす
      let failure = realtimeDirect.begin(
        sessionID: session, recordedTarget: target.id, isEnabled: true)
      switch failure {
      case nil: return true
      case .sensitiveInput: notice = .sensitiveInput
      case .unavailable: notice = .unsupportedTarget
      }
    } else {
      notice = .unsupportedTarget
    }
    hud.recordRealtimeDirectFallback(notice, for: session)
    return false
  }

  /// Realtime Direct で書き込んだセッションを、整形・一括挿入をせずに終える。
  ///
  /// 全体を書き込んだら、入力履歴（有効で機密入力でないとき）に認識テキストを保存し、取り消せるようにする。
  /// 途中でやめたら、書き込み側が全体をプレビューに出しているため HUD で知らせるだけにする
  private func finishRealtimeDirect(
    _ session: SessionID, text: String, completion: RealtimeDirectCompletion?,
    target: RecordedInsertionTarget, forwarding: Task<Void, Never>
  ) async {
    let finished = completion == .finished
    if !finished {
      hud.recordRealtimeDirectFallback(.stoppedAfterWriting, for: session)
    }
    guard apply(.refinementCompleted, session: session),
      apply(.insertionCompleted, session: session)
    else { return }
    // 待機に戻ったため、以降に次のセッションが始まりうる。次のセッションのタスクを消さないよう先に外す
    runTask = nil
    canUndoRealtimeDirect = finished
    if finished, !text.isEmpty {
      let inserter = inserter
      await history?.record(
        text, session: session, sensitivity: { inserter.sensitiveInputContext(for: target) })
    }
    await forwarding.value
    endRetention(session, completed: true)
  }

  /// このセッションで使う音声認識。録音を始める前に呼ぶ。
  ///
  /// クラウド STT なら同意・API キー・予算を確かめて認識器を作り、そろわなければ録音せずに理由を表示して `nil` を返す。
  /// 確かめる間にキャンセル・停止されたら、何も処理せずに `nil` を返す
  private func sessionRecognizer(
    _ session: SessionID, usesCloud: Bool
  ) async -> (any SpeechRecognizer)? {
    guard usesCloud, let cloudRecognition else {
      guard let recognizer else {
        failBeforeRecording(session, notice: .speechRecognitionNotConfigured)
        return nil
      }
      return recognizer
    }
    let preparation = await cloudRecognition.prepareRecognizer()
    guard isActive(session) else { return nil }
    guard machine.phase == .recording else {
      // 確かめる間に停止された。録音を始めておらず音声がないため、何も処理せずに待機へ戻る
      abandon(session)
      return nil
    }
    switch preparation {
    case .ready(let recognizer):
      return recognizer
    case .unavailable(let reason):
      failBeforeRecording(session, notice: .cloudSpeechRecognitionFailed(reason))
      return nil
    }
  }

  /// 録音のチャンクを一時音声の差し込み口に渡しながら、音声認識へ流す。録音が止まったら差し込み口に伝える。
  ///
  /// 音声認識がストリームを手放したら、認識し直せない構成では読むのをやめる（録音側は受け手の破棄として録音を止める）。
  /// 認識し直せる構成では、Worker の異常終了の後も録音全体を溜められるよう読み続ける（録音は調停役が停止・キャンセル・失敗で止める）。
  /// 音声認識へのストリームのバッファは無制限のため、`SpeechRecognizer` の実装は、読まなくなったらストリームを手放す
  /// （`STTWorkerSpeechRecognizer` は終端イベントで手放す）。手放さなくても、溜まるのは最大録音時間の分まで
  private func forward(
    _ chunks: AsyncStream<AudioChunk>, session: SessionID, keepsReading: Bool
  ) -> (audio: AsyncStream<AudioChunk>, task: Task<Void, Never>) {
    let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    let task = Task { [weak self] in
      for await chunk in chunks {
        self?.retain(chunk, session: session)
        continuation.yield(chunk)
      }
      continuation.finish()
      self?.finishRetaining(session)
    }
    if !keepsReading {
      continuation.onTermination = { _ in task.cancel() }
    }
    return (stream, task)
  }

  /// `end` を伝える前のセッションのチャンクだけを差し込み口に渡す
  private func retain(_ chunk: AudioChunk, session: SessionID) {
    guard retainedSession == session else { return }
    audioRetention?.append(chunk, to: session)
  }

  private func finishRetaining(_ session: SessionID) {
    guard retainedSession == session else { return }
    audioRetention?.finishRecording(session)
  }

  /// 差し込み口のメモリ上の録音全体で、同じセッションID のまま認識し直す（7章, AC-10）。完了しなければ `nil`
  private func recognizeAgain(
    _ session: SessionID, forwarding: Task<Void, Never>, recognizer: any SpeechRecognizer
  ) async -> String? {
    // 録音のチャンクをすべて差し込み口に渡し終えてから音声を取り出す
    await forwarding.value
    guard isActive(session), retainedSession == session,
      let audio = audioRetention?.recordedAudio(for: session)
    else { return nil }
    switch await recognizer.recognizeAgain(audio, session: session) {
    case .completed(let text): return text
    case .failed, .cancelled: return nil
    }
  }

  /// 録音が止まった理由を状態機械へ反映する（REC-04, REC-05）
  private func recordingEnded(_ end: AudioRecordingEnd, session: SessionID) {
    guard isActive(session), machine.phase == .recording else { return }
    switch end.reason {
    case .finished, .cancelled:
      // 停止操作による終わりと、音声認識が先に終わって音声を読まなくなった場合。後者は認識の結果の側で扱う
      return
    case .limitReached:
      machine.stopRecordingAtBufferLimit()
      reflect()
    case .interrupted(let interruption):
      switch machine.handleInterruption(
        interruption, capturedAudioDuration: end.capturedDuration, policy: interruptionPolicy)
      {
      case .stopped:
        reflect()
      case .aborted:
        // 処理できる音声がない。失敗を表示し、認識を止める
        runTask?.cancel()
        runTask = nil
        endRetention(session, completed: false)
        reflect()
      case .continued, .ignored:
        // 録音はすでに止まっているため、それまでの音声で認識へ進む。状態機械に停止理由を渡す API がないため
        // 停止理由は手動停止になり、割り込みの通知は出ない（macOS の録音側が流す割り込みは既定の方針ではすべて止める判定になる）
        machine.stopRecording(at: now())
        reflect()
      }
    }
  }

  /// 現在の段階のトークンでイベントを渡す。遷移したら `true`
  private func apply(_ kind: SessionEvent.Kind, session: SessionID) -> Bool {
    guard isActive(session), let token = machine.currentToken else { return false }
    guard case .applied = try? machine.handle(SessionEvent(token: token, kind: kind)) else {
      return false
    }
    reflect()
    return true
  }

  /// 現在の段階の失敗として表示する。録音中なら録音を止める
  private func fail(_ session: SessionID, notice: HUDNotice?) {
    guard isActive(session), let token = machine.currentToken else { return }
    if machine.phase == .recording { stopRecorder() }
    guard case .applied = try? machine.handle(SessionEvent(token: token, kind: .failed)) else {
      return
    }
    runTask = nil
    endRetention(session, completed: false)
    reflect(failureNotice: notice)
  }

  /// 録音を始める前に、認識の失敗として表示する（音声認識を使えないのに録音して、発話を失わせないため）
  private func failBeforeRecording(_ session: SessionID, notice: HUDNotice) {
    guard isActive(session) else { return }
    // 録音の段階を終えてから失敗にする。録音はまだ始めていないため、録音側は止めない
    machine.stopRecording(at: now())
    fail(session, notice: notice)
  }

  /// 音声がないまま停止されたセッションを、何も処理せずに待機へ戻す
  private func abandon(_ session: SessionID) {
    guard isActive(session), machine.cancel() != nil else { return }
    runTask = nil
    endRetention(session, completed: false)
    reflect()
  }

  /// マイクを開かずに失敗を表示する。音声認識が使えないのに録音して、発話を失わせないため
  private func failWithoutRecording(notice: HUDNotice) {
    guard machine.start(at: now()) != .ignored, machine.stopRecording(at: now()) != nil,
      let token = machine.currentToken
    else { return }
    _ = try? machine.handle(SessionEvent(token: token, kind: .failed))
    reflect(failureNotice: notice)
  }

  /// 録音を始める。前のセッションの開始が録音側に遅れて届いて録音中と言われたら、それを止めてから1回だけやり直す
  /// （キャンセル直後の開始で、新しいセッションを失敗にしないため, REC-04）
  private func startRecorder() async throws(AudioRecorderError) -> AudioRecording {
    do {
      return try await recorder.start(buffer: recordingBuffer)
    } catch .alreadyRecording {
      await stopRecorder().value
      return try await recorder.start(buffer: recordingBuffer)
    }
  }

  /// 一時音声の差し込み口に、`begin` を伝えたセッションの終わりを1回だけ伝える
  private func endRetention(_ session: SessionID, completed: Bool) {
    guard retainedSession == session else { return }
    retainedSession = nil
    audioRetention?.end(session, completed: completed)
  }

  @discardableResult
  private func stopRecorder() -> Task<Void, Never> {
    let previous = recorderStop
    let recorder = recorder
    let task = Task {
      await previous?.value
      await recorder.stop()
    }
    recorderStop = task
    return task
  }

  private func isActive(_ session: SessionID) -> Bool {
    machine.activeSession?.id == session
  }

  /// 次のセッションから使う設定を反映する。待機中（進行中のセッションがない）ときだけ呼ぶ
  private func applyNextSettings() {
    inputMode = nextSettings.inputMode
    guard nextSettings.configuration != machine.configuration else { return }
    // 状態機械の構成は変えられないため作り直す。待機中は進行中のセッションを持たないので、作り直しても失うものはない
    machine = SessionStateMachine(
      configuration: nextSettings.configuration, makeSessionID: makeSessionID)
  }

  /// 状態機械の変化を HUD・最大録音時間のタイマー・表示へ反映する
  private func reflect(failureNotice: HUDNotice? = nil) {
    let previous = phase
    phase = machine.phase
    if phase != previous { onPhaseChange?() }
    hud.update(from: machine, failureNotice: failureNotice)
    deadlineScheduler.schedule(at: machine.recordingDeadline) { [weak self] in
      self?.recordingDeadlineReached()
    }
  }

  /// 最大録音時間に達したら録音を止めて処理を続ける（REC-05）
  private func recordingDeadlineReached() {
    if machine.stopRecordingIfLimitReached(at: now()) != nil {
      reflect()
      stopRecorder()
    } else {
      // 期限より早く発火した場合は予約し直す
      reflect()
    }
  }

  /// 音声バッファの上限（REC-05）。最大録音時間ちょうどだと、タイマーより先にバッファの上限で止まり
  /// 通知が「音声の上限」になるため、1秒の余裕を持たせて最大録音時間のタイマーで止める
  private var recordingBuffer: AudioStreamBuffer {
    // 1秒未満の端数も含めて換算する（切り捨てるとタイマーより先にバッファの上限で止まる）
    let duration = machine.configuration.maxRecordingDuration + .seconds(1)
    let seconds =
      Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    let bytes = (seconds * Double(AudioRecordingPipeline.defaultSampleRate * 2)).rounded(.up)
    return AudioStreamBuffer(maxBytes: bytes >= Double(Int.max) ? Int.max : Int(bytes))
  }
}
