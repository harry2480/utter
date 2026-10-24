import Observation
import UtterAI
import UtterCore
import UtterSpeech

/// 録音 → 音声認識 → 整形 → 挿入 → HUD を1つのセッションとして進める調停役（REC-01〜06, INS-01, AC-02, AC-09）。
///
/// 状態は `SessionStateMachine` が持ち、ここは操作・非同期処理の結果を状態機械へ渡して、HUD と各部品を動かすだけにする。
/// 非同期処理は依頼したセッションを覚えておき、状態機械のセッションと違えば（キャンセル済み・別のセッション）結果を捨てる。
///
/// - 音声認識のエンジンが選ばれていない（`recognizer == nil`）なら、マイクを開かずに「音声認識が設定されていません」の失敗を表示する
/// - 録音開始時に入力対象（とスタイル区分の判定に使う前面アプリ）を記録し、挿入はその対象に対して確かめる（INS-01）
/// - 整形はローカル（Raw / Local Basic, AI-03）だけで、ネットワークに出ない（AC-02）
/// - 最大録音時間・音声バッファの上限・割り込みで録音を止めたら、それまでの音声を処理して HUD で知らせる（REC-05, iOS-PERF-03）
/// - キャンセルは録音〜整形中と失敗の表示中だけ受け付ける。挿入が始まったら取り消さない（REC-01）
/// - 処理中の開始操作は無視する（REC-06）
/// - 入力モードが Realtime Preview なら、認識の `partial` / `confirmed` を `TranscriptPreview` に溜めて HUD に出す（2.2節, AC-03）。
///   Instant（既定）では出さない。入力欄への挿入はどちらも停止後に一括で行う
/// - 発話本文はログに出さない。HUD に出すのは Realtime Preview の録音中・認識中の認識テキストだけ。
///   挿入できなければ挿入側がコピー可能なプレビューへ退避する（AC-09）
/// - 状態が変わるたびに `onPhaseChange` を呼ぶ（ショートカットの Esc の捕捉をセッション中だけ有効にするため, REC-01）
@MainActor
@Observable
final class SessionCoordinator {
  /// セッションの現在の状態。メニューの表示に使う
  private(set) var phase: SessionPhase = .idle
  /// 状態が変わるたびに呼ぶ。Esc のイベントタップのコールバックの中からも同期的に呼ばれるため、重い処理をしない
  @ObservationIgnored var onPhaseChange: (@MainActor () -> Void)?

  @ObservationIgnored private var machine: SessionStateMachine
  @ObservationIgnored private let recorder: any AudioRecorder
  @ObservationIgnored private let recognizer: (any SpeechRecognizer)?
  @ObservationIgnored private let refiner: any LocalRefiner
  @ObservationIgnored private let refinementMode: RefinementMode
  @ObservationIgnored private let showsRealtimePreview: Bool
  @ObservationIgnored private let styleResolver: AppStyleResolver
  @ObservationIgnored private let inserter: any SessionTextInserting
  @ObservationIgnored private let hud: HUDController
  @ObservationIgnored private let deadlineScheduler: any SessionDeadlineScheduling
  @ObservationIgnored private let interruptionPolicy: RecordingInterruptionPolicy
  @ObservationIgnored private let audioRetention: (any SessionAudioRetaining)?
  @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

  /// 進行中のセッションの非同期処理
  @ObservationIgnored private var runTask: Task<Void, Never>?
  /// 一時音声の差し込み口に `begin` を伝えて、まだ `end` を伝えていないセッション
  @ObservationIgnored private var retainedSession: SessionID?
  /// 録音の停止を順に行うためのタスク。次の録音はこれを待ってから始める（REC-04 の連打）
  @ObservationIgnored private var recorderStop: Task<Void, Never>?

  /// - Parameters:
  ///   - recognizer: 音声認識。エンジンが選ばれていなければ `nil`（Phase 0 の判定待ちで既定のエンジンを持たない）
  ///   - refiner: ローカルの整形（AI-03）。クラウド整形はここに渡さない
  ///   - refinementMode: 整形モード（TXT-01）
  ///   - showsRealtimePreview: 入力モードが Realtime Preview か（2.2節）。`false` は Instant（MVP 標準）。
  ///     入力モードの設定（#130）を結線するまでは構成値で選ぶ
  ///   - styleResolver: 録音開始時の前面アプリからスタイル区分を選ぶ（CTX-01）
  ///   - audioRetention: 一時音声の保存の差し込み口（7章, AC-10）。#132 の結線まで `nil`
  ///   - now: 現在時刻。テストでは手動で進める時刻を渡す
  init(
    configuration: SessionConfiguration = SessionConfiguration(),
    recorder: any AudioRecorder,
    recognizer: (any SpeechRecognizer)?,
    refiner: any LocalRefiner = LocalBasicRefiner(),
    refinementMode: RefinementMode,
    showsRealtimePreview: Bool = false,
    styleResolver: AppStyleResolver = AppStyleResolver(),
    inserter: any SessionTextInserting,
    hud: HUDController,
    deadlineScheduler: any SessionDeadlineScheduling,
    interruptionPolicy: RecordingInterruptionPolicy = RecordingInterruptionPolicy(),
    audioRetention: (any SessionAudioRetaining)? = nil,
    makeSessionID: @escaping @Sendable () -> SessionID = { SessionID() },
    now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    machine = SessionStateMachine(configuration: configuration, makeSessionID: makeSessionID)
    self.recorder = recorder
    self.recognizer = recognizer
    self.refiner = refiner
    self.refinementMode = refinementMode
    self.showsRealtimePreview = showsRealtimePreview
    self.styleResolver = styleResolver
    self.inserter = inserter
    self.hud = hud
    self.deadlineScheduler = deadlineScheduler
    self.interruptionPolicy = interruptionPolicy
    self.audioRetention = audioRetention
    self.now = now
    hud.onErrorDisplayExpired = { [weak self] in
      guard let self else { return }
      machine.dismissError()
      reflect()
    }
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

  /// 録音を始める。待機中でなければ何もしない（処理中の開始操作は無視する, REC-06）
  func startRecording() {
    guard machine.phase == .idle else { return }
    guard let recognizer else {
      failWithoutRecording(notice: .speechRecognitionNotConfigured)
      return
    }
    guard case .started(let token) = machine.start(at: now()) else { return }
    let session = token.sessionID
    // 入力対象は録音開始時に記録する（INS-01）
    let target = inserter.recordTarget()
    retainedSession = session
    audioRetention?.begin(session)
    reflect()
    runTask = Task { [weak self] in
      await self?.run(session: session, target: target, recognizer: recognizer)
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
    stopRecorder()
    endRetention(session, completed: false)
    reflect()
  }

  // MARK: - セッションの処理

  private func run(
    session: SessionID, target: RecordedInsertionTarget, recognizer: any SpeechRecognizer
  ) async {
    // 前の録音の停止が終わってから始める（連打で2つ目の録音を始めない, REC-04）
    await recorderStop?.value
    guard isActive(session) else { return }
    guard machine.phase == .recording else {
      // 録音を始める前に停止された。音声がないため何も処理せずに待機へ戻る
      abandon(session)
      return
    }

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

    let forwarding = forward(recording.chunks, session: session)
    var text: String?
    var completed = false
    // 別のセッション・順序の古いイベントは捨てる（認識の契約の SessionID と順序番号で確かめる）
    var filter = RecognitionEventFilter()
    filter.begin(session)
    // Realtime Preview の確定済み・暫定テキスト。セッションごとに作り直し、前の発話を残さない
    var preview = TranscriptPreview()
    for await event in recognizer.recognize(forwarding.audio, session: session) {
      guard isActive(session) else { return }
      guard filter.accept(event) == nil else { continue }
      switch event.kind {
      case .partial, .confirmed:
        if showsRealtimePreview {
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
      case .failed:
        completed = true
      }
      if completed { break }
    }
    guard isActive(session) else { return }

    // 録音の終わり（割り込み・上限到達）を状態機械へ反映してから認識の結果を渡す
    if machine.phase == .recording {
      await stopRecorder().value
      await ends.value
      guard isActive(session) else { return }
      if machine.phase == .recording {
        machine.stopRecording(at: now())
        reflect()
      }
    }
    guard machine.phase == .recognizing else { return }
    guard let text else {
      // 失敗、または終端イベントのないまま認識が終わった
      fail(session, notice: nil)
      return
    }
    guard apply(.recognitionCompleted, session: session) else { return }

    // 整形（ローカルのみ。ネットワークに出ない, AC-02）
    let style = styleResolver.style(forBundleID: target.app)
    let refined = refiner.refine(RefinementRequest(text: text, mode: refinementMode, style: style))
    guard apply(.refinementCompleted, session: session) else { return }

    // 挿入。自動挿入できなければ挿入側がプレビューへ退避する（文字列を失わない, AC-09）。
    // 挿入は始まったら取り消さないため、退避した場合も完了として待機へ戻る
    _ = await inserter.insert(refined, into: target)
    guard apply(.insertionCompleted, session: session) else { return }
    // 録音のチャンクをすべて差し込み口に渡し終えてから終わりを伝える
    await forwarding.task.value
    endRetention(session, completed: true)
    runTask = nil
  }

  /// 録音のチャンクを一時音声の差し込み口に渡しながら、音声認識へ流す。
  /// 音声認識がストリームを手放したら読むのをやめる（録音側は受け手の破棄として録音を止める）
  private func forward(
    _ chunks: AsyncStream<AudioChunk>, session: SessionID
  ) -> (audio: AsyncStream<AudioChunk>, task: Task<Void, Never>) {
    let retention = audioRetention
    let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    let task = Task {
      for await chunk in chunks {
        retention?.append(chunk, to: session)
        continuation.yield(chunk)
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return (stream, task)
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

  /// 状態機械の変化を HUD・最大録音時間のタイマー・表示へ反映する
  private func reflect(failureNotice: HUDNotice? = nil) {
    let previous = phase
    phase = machine.phase
    hud.update(from: machine, failureNotice: failureNotice)
    deadlineScheduler.schedule(at: machine.recordingDeadline) { [weak self] in
      self?.recordingDeadlineReached()
    }
    if phase != previous {
      onPhaseChange?()
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
