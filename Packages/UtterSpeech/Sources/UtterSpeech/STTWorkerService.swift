import UtterCore

/// STT Worker の中で、メッセージを受けてモデルのロード・推論・解放を行う（4章 STT Worker, 6章, AC-11）。
///
/// XPC には依存せず、Workers/macOSSTT の起動部が XPC のメッセージをこの型へ渡す。テストでは
/// `StubSTTWorkerConnection` がプロセス内でこの型を動かす。
///
/// - 同時に認識するのは1セッションまで。認識中に別のセッションの `start` が届いたら、そのセッションを
///   `failed(.resourceLimited)` にする（4章「モデルロード・推論は最大1件」）
/// - 登録のないエンジンは `failed(.modelUnavailable)` にする。既定のエンジンは持たない
/// - メモリ圧迫時は高負荷モデルをロードせず `failed(.resourceLimited)` にする（AC-11）
/// - 推論が終わったら `ModelRetentionPolicy.retention(in:)` に従ってモデルを解放・保持する。
///   保持の設定を受け取る前は、推論後すぐに解放する（省電力・安定性を優先する安全側）
/// - 音声・認識テキストはログに出さない
public actor STTWorkerService {
  private struct LoadedModel {
    let engine: STTEngineKind
    let recognizer: any SpeechRecognizer
  }

  private struct ActiveSession {
    let session: SessionID
    let audio: AsyncStream<AudioChunk>.Continuation
    let task: Task<Void, Never>
  }

  private let loaders: [STTEngineKind: any SpeechModelLoader]
  private let sleep: @Sendable (Duration) async throws -> Void
  private var resources: STTWorkerResources?
  private var loaded: LoadedModel?
  private var active: ActiveSession?
  private var releaseTask: Task<Void, Never>?
  /// 解放の予約を取り消したかを見分ける番号。予約のたびに増やす
  private var releaseGeneration: UInt64 = 0
  private var send: (@Sendable (STTWorkerResponse) -> Void)?

  /// - Parameters:
  ///   - loaders: 使えるエンジンとそのローダー。実エンジン（SpeechAnalyzer / WhisperKit）のアダプターはここに登録する
  ///   - sleep: バランスモードの保持時間を待つ実装。テストでは実時間を待たない
  public init(
    loaders: [STTEngineKind: any SpeechModelLoader],
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.loaders = loaders
    self.sleep = sleep
  }

  /// モデルをロード済みか
  public var isModelLoaded: Bool {
    loaded != nil
  }

  /// ロード済みのモデルのエンジン
  public var loadedEngine: STTEngineKind? {
    loaded?.engine
  }

  /// `incoming` のメッセージを届いた順に処理し、応答を `send` で返す。
  ///
  /// `incoming` が終わったら（接続が切れたら）認識を止め、モデルを解放して戻る。
  public func run(
    incoming: AsyncStream<STTWorkerRequest>,
    send: @escaping @Sendable (STTWorkerResponse) -> Void
  ) async {
    attach(send)
    for await request in incoming {
      await handle(request)
    }
    detach()
  }

  /// 応答の送り先を設定する。`run` を使わずに `handle` を直接呼ぶテスト用
  func attach(_ send: @escaping @Sendable (STTWorkerResponse) -> Void) {
    self.send = send
  }

  /// 接続が切れたときの後始末。認識を止め、モデルを解放する
  func detach() {
    stopActiveSession()
    cancelScheduledRelease()
    loaded = nil
    send = nil
  }

  func handle(_ request: STTWorkerRequest) async {
    switch request {
    case .start(let session, let engine):
      await start(session, engine: engine)
    case .audio(let session, let chunk):
      guard active?.session == session else { return }
      active?.audio.yield(chunk)
    case .finishAudio(let session):
      guard active?.session == session else { return }
      active?.audio.finish()
    case .cancel(let session):
      guard active?.session == session else { return }
      stopActiveSession()
      applyRetention()
    case .updateResources(let resources):
      // 同じ値の送り直しで保持時間のタイマーを張り直さない（張り直すとバランスモードで解放されなくなる）
      guard self.resources != resources else { return }
      self.resources = resources
      if active == nil {
        applyRetention()
      }
    }
  }

  private func start(_ session: SessionID, engine: STTEngineKind) async {
    guard active == nil else {
      fail(session, .resourceLimited)
      return
    }
    guard let loader = loaders[engine] else {
      fail(session, .modelUnavailable)
      return
    }
    cancelScheduledRelease()
    if let resources,
      resources.policy.loadDecision(for: loader.weight, in: resources.deviceState)
        == .deferredForMemoryPressure
    {
      // 圧迫中にロード済みのモデルを残さない（ModelRetentionPolicy と同じ方針）
      loaded = nil
      fail(session, .resourceLimited)
      return
    }
    if loaded?.engine != engine {
      loaded = nil
      do {
        loaded = LoadedModel(engine: engine, recognizer: try await loader.load())
      } catch {
        fail(session, error)
        return
      }
    }
    guard let recognizer = loaded?.recognizer, let send else { return }

    let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = recognizer.recognize(audio, session: session)
    let task = Task {
      var nextSequence: UInt64 = 0
      for await event in events {
        // 止めたセッションのイベントは返さない
        if Task.isCancelled { return }
        send(.event(event))
        nextSequence = event.sequence &+ 1
        if event.kind.isTerminal {
          self.sessionDidFinish(session)
          return
        }
      }
      // 止めていないのに終端イベントなしで終わったら、受け手が待ち続けないよう失敗にする
      guard !Task.isCancelled else { return }
      send(
        .event(
          RecognitionEvent(sessionID: session, sequence: nextSequence, kind: .failed(.engineFailed))
        ))
      self.sessionDidFinish(session)
    }
    active = ActiveSession(session: session, audio: continuation, task: task)
  }

  private func sessionDidFinish(_ session: SessionID) {
    guard let active, active.session == session else { return }
    active.audio.finish()
    self.active = nil
    applyRetention()
  }

  /// 受け手がいなくなったセッションの認識を止める。終端イベントは流さない
  private func stopActiveSession() {
    guard let active else { return }
    active.task.cancel()
    active.audio.finish()
    self.active = nil
  }

  private func fail(_ session: SessionID, _ error: SpeechRecognitionError) {
    send?(.event(RecognitionEvent(sessionID: session, sequence: 0, kind: .failed(error))))
  }

  /// 推論の後、または設定・端末の状態が変わったときに、ロード済みのモデルを解放・保持する（6章）
  private func applyRetention() {
    guard loaded != nil, active == nil else { return }
    cancelScheduledRelease()
    // 設定を受け取る前は、推論後すぐに解放する
    let retention = resources.map { $0.policy.retention(in: $0.deviceState) } ?? .releaseNow
    switch retention {
    case .releaseNow:
      loaded = nil
    case .keep(let duration):
      let generation = releaseGeneration
      let sleep = sleep
      releaseTask = Task {
        do {
          try await sleep(duration)
        } catch {
          return
        }
        self.releaseIfStillScheduled(generation)
      }
    case .keepUntilStateChanges:
      break
    }
  }

  private func releaseIfStillScheduled(_ generation: UInt64) {
    guard generation == releaseGeneration, active == nil else { return }
    releaseTask = nil
    loaded = nil
  }

  private func cancelScheduledRelease() {
    releaseGeneration &+= 1
    releaseTask?.cancel()
    releaseTask = nil
  }
}
