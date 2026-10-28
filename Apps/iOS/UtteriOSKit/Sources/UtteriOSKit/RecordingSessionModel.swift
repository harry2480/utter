import Foundation
import Observation
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// 本体アプリの録音セッションの進行（iOS-04, iOS-07, iOS-PERF-03）。
///
/// 録音 → 音声認識 → 整形 → 共有結果の保存を `SessionStateMachine` に沿って進め、
/// 画面に出す状態・通知・救済用の結果一覧を持つ。iOS では状態機械の `inserting` を「共有結果の保存」に使う。
/// - 録音は `AudioRecorder`、認識は `SpeechRecognizer`、ローカル整形は `LocalRefiner` を注入する。
///   クラウド整形は `CloudRefinement` を渡したときだけ使い、同意・API キー・予算がそろわなければローカル整形だけを使う（iOS-10）
/// - 割り込みは `handle(_:)` で受け、`RecordingInterruptionPolicy` に従って止める。止めたときも取得済みの音声は処理する
/// - 時刻・待ち時間・セッションIDは注入でき、テストでは実時間を待たない
/// - 画面に出す録音の進み（経過時間・音量の波形・途中の文字）と、保存した結果の文体・整形先を持つ（#201）。
///   音量は値だけを持ち、音声は持たない。途中の文字と結果の本文は画面に出すだけで、記録しない
@MainActor
@Observable
public final class RecordingSessionModel {
  /// 現在の状態
  public private(set) var phase: SessionPhase = .idle
  /// 直近のセッションで録音を自動で止めた理由
  public private(set) var stopNotice: RecordingStopNotice?
  /// 直近のセッションを完了できなかった理由
  public private(set) var failure: RecordingFailure?
  /// 保存できなかった結果の本文。次の録音を始めるまで、この画面でコピーできる
  public private(set) var unsavedText: String?
  /// 救済画面に出す保存済みの結果（iOS-07）
  public private(set) var rescueList = SharedResultRescueList(items: [], unavailableCount: 0)
  /// 保存済みの結果を読み込めなかった（端末のロック中など）
  public private(set) var isRescueListUnavailable = false
  /// 直近のコピー操作の結果
  public private(set) var copyNotice: ResultCopyNotice?
  /// 直近のセッションで、クラウド整形を使えずローカル整形の結果を保存した理由（4.1節）
  public private(set) var refinementNotice: RefinementNotice?
  /// 直近の「この文章を消す」「録音し直す」の結果
  public private(set) var discardNotice: ResultDiscardNotice?
  /// キーボードと結果を共有しているか
  public let sharing: SharedResultSharing
  /// 次に録音するセッションの文体（整形モード, TXT-01）。録音を始めたときの値をそのセッションに使う
  public var refinementMode: RefinementMode
  /// 直近（進行中を含む）のセッションの文体。まだ録音していなければ `nil`
  public private(set) var sessionRefinementMode: RefinementMode?
  /// 録音中の途中の文字（確定済みと聞き取り中）。STT が途中経過を返す場合だけ埋まる。録音を始めるたびに空にする
  public private(set) var transcript = TranscriptPreview()
  /// 録音中の音量の波形。録音を始めるたびに空にする
  public private(set) var levels = AudioLevelHistory()
  /// 保存した結果の文体と整形先。このアプリを起動してから保存した結果だけを持つ（本文は持たない）
  public private(set) var resultContexts: [SessionID: SavedResultContext] = [:]

  @ObservationIgnored private var stateMachine: SessionStateMachine
  @ObservationIgnored private var capture: Capture?
  @ObservationIgnored private var isPreparing = false
  /// 一覧の読み直しの世代。後から始めた読み直しの結果だけを反映する
  @ObservationIgnored private var refreshGeneration = 0
  @ObservationIgnored private let dependencies: Dependencies

  /// 進行中のセッションの録音と認識
  private struct Capture {
    let sessionID: SessionID
    let audio: BoundedAudioStream
    var recognition: Task<Void, Never>?
    var deadline: Task<Void, Never>?
  }

  private struct Dependencies {
    let recorder: any AudioRecorder
    let recognizer: any SpeechRecognizer
    let refiner: any LocalRefiner
    let cloudRefinement: CloudRefinement?
    let store: SharedResultStore
    let rescue: SharedResultRescueCoordinator
    /// 「この文章を消す」に使う。本体アプリは挿入しない
    let insertion: SharedResultInsertionCoordinator
    let copier: any SharedResultTextCopier
    let policy: RecordingInterruptionPolicy
    let audioBuffer: AudioStreamBuffer
    let resultConfiguration: SharedResultConfiguration
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (Duration) async throws -> Void
    let date: @Sendable () -> Date
  }

  /// - Parameters:
  ///   - recorder: 録音の実装
  ///   - recognizer: 音声認識。STT エンジンの判定（#54）までは `UnconfiguredSpeechRecognizer`
  ///   - refiner: ローカル整形。既定は Local Basic（AI-03）。クラウド整形の退避先にも使う
  ///   - cloudRefinement: クラウド整形。`nil` ならローカル整形だけを使う
  ///   - refinementMode: 最初の整形モード（文体）。既定は Natural。後から `refinementMode` で変えられる
  ///   - storage: 共有結果の保存先
  ///   - copier: 救済画面のコピー先（クリップボード）
  ///   - policy: 割り込みへの対応方針
  ///   - sessionConfiguration: 最大録音時間など
  ///   - audioBuffer: 音声バッファの上限（REC-05）
  ///   - resultConfiguration: 共有結果の有効期限など
  ///   - makeSessionID: セッションIDの生成
  ///   - now: 単調増加の現在時刻（最大録音時間の判定）
  ///   - sleep: 最大録音時間まで待つ実装
  ///   - date: 実時刻（共有結果の作成時刻・期限の判定）
  public init(
    recorder: any AudioRecorder,
    recognizer: any SpeechRecognizer,
    refiner: any LocalRefiner = LocalBasicRefiner(),
    cloudRefinement: CloudRefinement? = nil,
    refinementMode: RefinementMode = .natural,
    storage: SharedResultStorage,
    copier: any SharedResultTextCopier,
    policy: RecordingInterruptionPolicy = RecordingInterruptionPolicy(),
    sessionConfiguration: SessionConfiguration = SessionConfiguration(),
    audioBuffer: AudioStreamBuffer = AudioStreamBuffer(),
    resultConfiguration: SharedResultConfiguration = SharedResultConfiguration(),
    makeSessionID: @escaping @Sendable () -> SessionID = { SessionID() },
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    date: @escaping @Sendable () -> Date = { Date() }
  ) {
    sharing = storage.sharing
    self.refinementMode = refinementMode
    stateMachine = SessionStateMachine(
      configuration: sessionConfiguration, makeSessionID: makeSessionID)
    dependencies = Dependencies(
      recorder: recorder, recognizer: recognizer, refiner: refiner,
      cloudRefinement: cloudRefinement, store: storage.store,
      rescue: SharedResultRescueCoordinator(store: storage.store, copier: copier, now: date),
      insertion: SharedResultInsertionCoordinator(
        store: storage.store, inserter: MainAppDoesNotInsert(), now: date),
      copier: copier, policy: policy, audioBuffer: audioBuffer,
      resultConfiguration: resultConfiguration, now: now, sleep: sleep, date: date)
  }

  /// 録音中か（画面の自動ロックを止めるかの判断に使う）
  public var isRecording: Bool { phase == .recording }

  /// 新しい録音を始められるか（待機中か、失敗の表示中）
  public var canStartRecording: Bool {
    switch phase {
    case .idle, .error: true
    case .recording, .recognizing, .refining, .inserting: false
    }
  }

  /// 最大録音時間（REC-05）
  public var maxRecordingDuration: Duration { stateMachine.configuration.maxRecordingDuration }

  /// 録音中なら、経過時間と最大録音時間。録音中でなければ `nil`
  public func recordingProgress() -> RecordingProgress? {
    guard stateMachine.phase == .recording, let session = stateMachine.activeSession else {
      return nil
    }
    return RecordingProgress(
      elapsed: session.startedAt.duration(to: dependencies.now()),
      maxDuration: maxRecordingDuration)
  }

  /// 開始・停止の操作（REC-06）。待機中なら録音を始め、録音中なら止める。
  public func toggleRecording() async {
    if phase == .recording {
      stopRecording()
    } else {
      await startRecording()
    }
  }

  /// 録音を始める。失敗の表示中なら閉じてから始める。処理中は何もしない。
  public func startRecording() async {
    guard !isPreparing else { return }
    if case .error = stateMachine.phase {
      dismissError()
    }
    guard stateMachine.phase == .idle else { return }
    isPreparing = true
    defer { isPreparing = false }
    stopNotice = nil
    failure = nil
    copyNotice = nil
    discardNotice = nil
    refinementNotice = nil

    guard await dependencies.recorder.requestPermission() else {
      failure = .microphoneDenied
      return
    }
    guard case .started(let token) = stateMachine.start(at: dependencies.now()) else { return }
    let sessionID = token.sessionID
    sessionRefinementMode = refinementMode
    transcript = TranscriptPreview()
    levels = AudioLevelHistory()
    let (audio, chunks) = BoundedAudioStream.make(buffer: dependencies.audioBuffer)
    do {
      try dependencies.recorder.start(
        onChunk: { [weak self] chunk in
          // 波形には音量の値だけを渡し、音声は渡さない
          let level = AudioLevelHistory.level(of: chunk.samples)
          if case .limitReached = audio.yield(chunk) {
            Task { @MainActor in self?.bufferLimitReached(sessionID) }
          }
          Task { @MainActor in self?.receiveLevel(level, for: sessionID) }
        },
        onFailure: { [weak self] in
          Task { @MainActor in self?.recorderFailed(sessionID) }
        })
    } catch {
      audio.finish()
      dependencies.recorder.stop()
      apply(.failed, token: token)
      failure = .recordingUnavailable
      return
    }

    var capture = Capture(sessionID: sessionID, audio: audio)
    let events = dependencies.recognizer.recognize(chunks, session: sessionID)
    capture.recognition = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.receive(event)
        if event.kind.isTerminal { return }
      }
    }
    capture.deadline = Task { [weak self] in
      await self?.watchDeadline(sessionID)
    }
    self.capture = capture
    // 保存できなかった本文は、新しい録音を始められたときにだけ消す（始められなければまだコピーできる）
    unsavedText = nil
    phase = stateMachine.phase
  }

  /// 利用者の操作で録音を止め、認識へ進む。録音中でなければ何もしない。
  public func stopRecording() {
    guard stateMachine.stopRecording(at: dependencies.now()) != nil else { return }
    if stateMachine.activeSession?.stopReason == .maxDurationReached {
      stopNotice = .maxDurationReached
    }
    endCapture(cancelsRecognition: false)
    phase = stateMachine.phase
  }

  /// 録音〜整形中のセッションを破棄する（REC-01）。保存中は取り消せないため何もしない。
  public func cancel() {
    guard stateMachine.cancel() != nil else { return }
    endCapture(cancelsRecognition: true)
    capture = nil
    stopNotice = nil
    phase = stateMachine.phase
  }

  /// 失敗の表示を閉じる。保存できなかった本文は次の録音まで残す。
  public func dismissError() {
    if stateMachine.dismissError() {
      endCapture(cancelsRecognition: true)
      capture = nil
    }
    failure = nil
    phase = stateMachine.phase
  }

  /// OS の通知を割り込みとして処理する（iOS-PERF-03）。
  public func handle(_ signal: RecordingSystemSignal) {
    handleInterruption(signal.recordingInterruption)
  }

  /// 割り込みを `RecordingInterruptionPolicy` に従って処理する。録音中でなければ何もしない。
  public func handleInterruption(_ interruption: RecordingInterruption) {
    guard let capture else { return }
    let outcome = stateMachine.handleInterruption(
      interruption, capturedAudioDuration: capturedDuration(capture.audio),
      policy: dependencies.policy)
    switch outcome {
    case .continued, .ignored:
      return
    case .stopped:
      if case .interrupted(let cause) = stateMachine.activeSession?.stopReason {
        stopNotice = .interrupted(cause)
      }
      endCapture(cancelsRecognition: false)
    case .aborted(let cause):
      failure = .interruptedWithoutAudio(cause)
      endCapture(cancelsRecognition: true)
      self.capture = nil
    }
    phase = stateMachine.phase
  }

  // MARK: 救済導線（iOS-07）

  /// 起動時・前面に戻ったときに呼ぶ。期限切れ・挿入済みの結果を削除し、中断された挿入を復旧してから一覧を読み直す
  /// （iOS-IPC-05, iOS-IPC-06）。
  public func prepareResults() async {
    _ = try? await dependencies.store.cleanUp(at: dependencies.date())
    await refreshResults()
  }

  /// 保存済みの結果の一覧を読み直す。
  public func refreshResults() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    let loaded: SharedResultRescueList
    do {
      loaded = try await dependencies.rescue.items()
    } catch {
      guard generation == refreshGeneration else { return }
      rescueList = SharedResultRescueList(items: [], unavailableCount: 0)
      isRescueListUnavailable = true
      return
    }
    // 起動時・前面への復帰・保存後・コピー後の読み直しが重なっても、古い一覧で上書きしない
    guard generation == refreshGeneration else { return }
    rescueList = loaded
    isRescueListUnavailable = false
    // 一覧から消えた結果（期限切れ・挿入済み・消した結果）の文体と整形先は持ち続けない
    let sessionIDs = Set(loaded.items.map(\.sessionID))
    resultContexts = resultContexts.filter { sessionIDs.contains($0.key) }
  }

  /// 保存済みの結果をクリップボードへコピーする。コピーした結果はキーボードからは挿入できなくなる。
  public func copyResult(_ sessionID: SessionID) async {
    do {
      copyNotice =
        switch try await dependencies.rescue.copy(sessionID: sessionID) {
        case .copied: .copied
        case .conflicted, .notCopied, .notFound: .notCopied
        }
    } catch {
      copyNotice = .failed
    }
    await refreshResults()
  }

  /// 保存できなかった結果の本文をクリップボードへコピーする。
  public func copyUnsavedText() async {
    guard let unsavedText else { return }
    await dependencies.copier.copy(unsavedText)
    copyNotice = .copied
  }

  /// 利用者の「この文章を消す」操作を受けて、保存済みの結果を消す（iOS-IPC-01〜03, iOS-IPC-05）。
  ///
  /// キーボードの「消す」と同じく挿入済みとして記録してから削除するため、キーボードからも入れられなくなる。
  /// キーボードが挿入中（猶予時間内）の結果は消さない。
  /// - Returns: 消した（すでになかった場合を含む）か
  @discardableResult
  public func discardResult(_ sessionID: SessionID) async -> Bool {
    copyNotice = nil
    let notice: ResultDiscardNotice
    do {
      notice =
        switch try await dependencies.insertion.discard(sessionID: sessionID) {
        case .dismissed, .notFound: .discarded
        case .notDismissed: .inserting
        case .conflicted: .conflicted
        }
    } catch {
      notice = .failed
    }
    discardNotice = notice
    if notice == .discarded {
      resultContexts[sessionID] = nil
    }
    await refreshResults()
    return notice == .discarded
  }

  /// 利用者の「録音し直す」操作を受けて、保存済みの結果を消してから新しい録音を始める。
  ///
  /// 同じ発話の結果を二つ残さないよう、消せなかったときは録音を始めない。録音を始められない段階では何もしない。
  public func recordAgain(_ sessionID: SessionID) async {
    guard canStartRecording, !isPreparing else { return }
    guard await discardResult(sessionID) else { return }
    await startRecording()
  }

  // MARK: 録音の終了と認識の結果

  private func capturedDuration(_ audio: BoundedAudioStream) -> Duration {
    let sampleRate = dependencies.recorder.sampleRate
    guard sampleRate > 0 else { return .zero }
    // 受け入れたバイト数は PCM16 換算（1サンプル2バイト）
    return .seconds(Double(audio.byteCount / 2) / Double(sampleRate))
  }

  /// 録音を止め、音声のストリームを終える。`cancelsRecognition` なら認識も止める。何度呼んでもよい
  private func endCapture(cancelsRecognition: Bool) {
    guard let capture else { return }
    dependencies.recorder.stop()
    capture.audio.finish()
    capture.deadline?.cancel()
    if cancelsRecognition {
      capture.recognition?.cancel()
    }
  }

  private func watchDeadline(_ sessionID: SessionID) async {
    while capture?.sessionID == sessionID, let deadline = stateMachine.recordingDeadline {
      let remaining = dependencies.now().duration(to: deadline)
      do {
        try await dependencies.sleep(max(remaining, .zero))
      } catch {
        return
      }
      guard capture?.sessionID == sessionID else { return }
      if stateMachine.stopRecordingIfLimitReached(at: dependencies.now()) != nil {
        stopNotice = .maxDurationReached
        endCapture(cancelsRecognition: false)
        phase = stateMachine.phase
        return
      }
    }
  }

  /// 録音中のセッションの音量を波形に足す
  private func receiveLevel(_ level: Float, for sessionID: SessionID) {
    guard capture?.sessionID == sessionID, stateMachine.phase == .recording else { return }
    levels.append(level)
  }

  private func bufferLimitReached(_ sessionID: SessionID) {
    guard capture?.sessionID == sessionID,
      stateMachine.stopRecordingAtBufferLimit() != nil
    else { return }
    stopNotice = .bufferLimitReached
    endCapture(cancelsRecognition: false)
    phase = stateMachine.phase
  }

  /// 録音を続けられなくなった。録音エンジンを作り直す必要があるメディアサービスのリセットと同じに扱い、
  /// 取得済みの音声は処理する
  private func recorderFailed(_ sessionID: SessionID) {
    guard capture?.sessionID == sessionID else { return }
    handleInterruption(.mediaServicesReset)
  }

  private func receive(_ event: RecognitionEvent) async {
    guard capture?.sessionID == event.sessionID else { return }
    switch event.kind {
    case .partial, .confirmed:
      // 途中の文字は画面に出すだけで、保存・記録しない
      transcript.apply(event.kind)
    case .completed(let text):
      finishRecordingEarly()
      guard stateMachine.phase == .recognizing, let token = stateMachine.currentToken else {
        return
      }
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        failure = .noSpeech
        apply(.failed, token: token)
        return
      }
      apply(.recognitionCompleted, token: token)
      await refineAndSave(text)
    case .failed(let error):
      finishRecordingEarly()
      guard stateMachine.phase == .recognizing, let token = stateMachine.currentToken else {
        return
      }
      failure = error == .modelUnavailable ? .recognizerUnavailable : .recognitionFailed
      apply(.failed, token: token)
    }
  }

  /// 認識が録音より先に終わった場合は、録音を止めて認識の段階へ進める（認識は終端イベントの後に音声を読まない）
  private func finishRecordingEarly() {
    guard stateMachine.phase == .recording else { return }
    stateMachine.stopRecording(at: dependencies.now())
    endCapture(cancelsRecognition: false)
  }

  private func refineAndSave(_ text: String) async {
    guard stateMachine.phase == .refining, let refining = stateMachine.currentToken else { return }
    let mode = sessionRefinementMode ?? refinementMode
    let request = RefinementRequest(text: text, mode: mode)
    let refined: String
    let route: SessionRefinementRoute
    if let cloud = dependencies.cloudRefinement {
      let result: SessionRefinementResult
      do {
        result = try await cloud.refine(request, localRefiner: dependencies.refiner)
      } catch {
        // キャンセルした操作が状態を戻していなければ、整形中のまま残さず失敗として閉じる
        if stateMachine.currentToken == refining {
          apply(.failed, token: refining)
        }
        return
      }
      // 整形を待つ間にキャンセルされたセッションの結果は使わない
      guard stateMachine.currentToken == refining else { return }
      refined = result.text
      route = result.route
      refinementNotice = RefinementNotice(route: result.route)
    } else {
      refined = dependencies.refiner.refine(request)
      route = mode == .raw ? .localOnly(.rawMode) : .localOnly(.cloudNotConfigured)
    }
    guard !refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      failure = .noSpeech
      apply(.failed, token: refining)
      return
    }
    apply(.refinementCompleted, token: refining)
    guard let saving = stateMachine.currentToken else { return }
    let result = SharedResult(
      sessionID: saving.sessionID, text: refined, createdAt: dependencies.date(),
      configuration: dependencies.resultConfiguration)
    do {
      try await dependencies.store.save(result, expectedRevision: nil)
    } catch {
      // 保存できなくても発話を失わないよう、本文はこの画面に残してコピーできるようにする
      unsavedText = refined
      failure = .saveFailed
      apply(.failed, token: saving)
      return
    }
    apply(.insertionCompleted, token: saving)
    capture = nil
    // 一覧の読み直しより前に持つ（読み直しで一覧にない結果の値を捨てるため）
    resultContexts[saving.sessionID] = SavedResultContext(
      mode: mode, refinement: ProcessingDestination(refinementFor: mode, route: route))
    await refreshResults()
  }

  private func apply(_ kind: SessionEvent.Kind, token: SessionToken) {
    do {
      _ = try stateMachine.handle(SessionEvent(token: token, kind: kind))
    } catch {
      assertionFailure("状態機械が許可しない遷移を依頼した")
    }
    phase = stateMachine.phase
  }
}

/// 本体アプリは入力欄へ挿入しない。`SharedResultInsertionCoordinator` は「この文章を消す」（`discard`）にだけ使い、
/// `insert` は呼ばない。呼ばれても挿入せず、確認できなかったとして返す
private struct MainAppDoesNotInsert: SharedResultTextInserter {
  func insert(_ text: String) async -> SharedResultInsertionConfirmation {
    .unknown
  }
}
