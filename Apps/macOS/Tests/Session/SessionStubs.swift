import Synchronization
import UtterCore
import UtterSpeech

/// 手動で進める時刻。
@MainActor
final class ManualClock {
  var now = ContinuousClock.now

  func advance(by duration: Duration) {
    now = now.advanced(by: duration)
  }
}

/// 表示した HUD を記録する。
@MainActor
final class StubHUDPresenter: HUDPresenting {
  private(set) var shown: [HUDPresentation] = []
  private(set) var isVisible = false

  var current: HUDPresentation? {
    isVisible ? shown.last : nil
  }

  /// 表示した1行目。録音中の経過時間・入力音量だけが変わった更新のように、同じ1行目が続く表示は1つにまとめる
  var titles: [String] {
    shown.map(\.title).reduce(into: [String]()) { result, title in
      if result.last != title { result.append(title) }
    }
  }

  func show(_ presentation: HUDPresentation) {
    shown.append(presentation)
    isVisible = true
  }

  func hide() {
    isVisible = false
  }

  /// 記録を消す（1つのテストで複数のセッションを確かめるとき）
  func reset() {
    shown = []
    isVisible = false
  }
}

/// 予約を覚えておき、テストから呼ぶ。HUD の更新と最大録音時間の予約の両方に使う。
@MainActor
final class StubScheduler: HUDRefreshScheduling, SessionDeadlineScheduling {
  private(set) var deadline: ContinuousClock.Instant?
  private var action: (@MainActor () -> Void)?

  func schedule(at deadline: ContinuousClock.Instant?, _ action: @escaping @MainActor () -> Void) {
    self.deadline = deadline
    self.action = deadline == nil ? nil : action
  }

  /// 予約した処理を呼ぶ。予約がなければ何もしない
  func fire() {
    let action = action
    deadline = nil
    self.action = nil
    action?()
  }
}

/// 認識したテキストを変えずに返す整形（Raw 相当）。整形の選択を扱わないテストで使う
@MainActor
final class StubSessionRefiner: SessionRefining {
  /// 停止→挿入の計測区間の判定に返す値。整形の結果には影響しない
  var selectsCloudRefinement = false

  func refinementSummary(frontmostApp: String?) -> HUDRefinementSummary {
    HUDRefinementSummary(mode: .raw, style: nil)
  }

  func refine(
    _ transcript: String,
    frontmostApp: String?,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext,
    willSend: @escaping @MainActor (CloudAIProviderKind) -> Void
  ) async throws(CancellationError) -> SessionRefinementResult {
    SessionRefinementResult(text: transcript, route: .localOnly(.rawMode))
  }
}

/// 入力対象の記録と挿入を記録する。`holdsInsertion` なら `resumeInsertion()` まで挿入を終えない。
@MainActor
final class StubSessionInserter: SessionTextInserting {
  var target = RecordedInsertionTarget(
    id: InsertionTargetID(rawValue: "field"), app: "com.example.editor")
  var outcome = InsertionOutcome.finished(.verified(.accessibility))
  var holdsInsertion = false
  private(set) var recordCount = 0
  private(set) var inserted: [(text: String, target: RecordedInsertionTarget)] = []
  private var pending: CheckedContinuation<Void, Never>?

  var isHoldingInsertion: Bool {
    pending != nil
  }

  func recordTarget() -> RecordedInsertionTarget {
    recordCount += 1
    return target
  }

  func insert(_ text: String, into target: RecordedInsertionTarget) async -> InsertionReport {
    inserted.append((text, target))
    if holdsInsertion {
      await withCheckedContinuation { pending = $0 }
    }
    return InsertionReport(outcome: outcome, attempts: [], clipboardRestore: nil)
  }

  func resumeInsertion() {
    pending?.resume()
    pending = nil
  }

  /// 今の入力先の状態。既定は機密入力でない入力欄
  var sensitiveContext = SensitiveInputContext(
    secureField: .off, secureEventInput: .off, app: "com.example.editor")
  private(set) var sensitiveContextRequests = 0

  func sensitiveInputContext(for target: RecordedInsertionTarget) -> SensitiveInputContext {
    sensitiveContextRequests += 1
    return sensitiveContext
  }
}

/// 一時音声の差し込み口の呼び出しを記録し、届いたチャンクをメモリ上の録音音声に溜める。
@MainActor
final class StubAudioRetention: SessionAudioRetaining {
  enum Event: Equatable {
    case begin(SessionID)
    case finishRecording(SessionID)
    case end(SessionID, completed: Bool)
  }

  private(set) var events: [Event] = []
  private(set) var appendedSampleCount = 0
  private var audio: (session: SessionID, audio: RecordedAudio)?

  /// `finishRecording` を除いた記録（録音の止まり方で順序の変わらないもの）
  var lifecycle: [Event] {
    events.filter {
      if case .finishRecording = $0 { return false }
      return true
    }
  }

  func begin(_ session: SessionID) {
    events.append(.begin(session))
    audio = nil
  }

  func append(_ chunk: AudioChunk, to session: SessionID) {
    appendedSampleCount += chunk.samples.count
    if audio == nil, let recorded = try? RecordedAudio(sampleRate: chunk.sampleRate) {
      audio = (session, recorded)
    }
    try? audio?.audio.append(chunk)
  }

  func finishRecording(_ session: SessionID) {
    events.append(.finishRecording(session))
  }

  func recordedAudio(for session: SessionID) -> RecordedAudio? {
    audio?.session == session ? audio?.audio : nil
  }

  func end(_ session: SessionID, completed: Bool) {
    events.append(.end(session, completed: completed))
    audio = nil
  }
}

/// 認識をやり直すかの判断を固定の値で返し、問い合わせを記録する。
final class StubRecognitionRecovery: SessionRecognitionRecovering {
  private let answer: Bool
  private let asked = Mutex<[SpeechRecognitionError]>([])

  init(answer: Bool) {
    self.answer = answer
  }

  var questions: [SpeechRecognitionError] {
    asked.withLock { $0 }
  }

  func shouldRecognizeAgain(_ session: SessionID, after error: SpeechRecognitionError) async -> Bool
  {
    asked.withLock { $0.append(error) }
    return answer
  }
}

/// テストから認識のイベントを流す音声認識。認識を依頼された順に番号を振る。
final class ScriptedSpeechRecognizer: SpeechRecognizer {
  private struct Run {
    let session: SessionID
    let continuation: AsyncStream<RecognitionEvent>.Continuation
    var nextSequence: UInt64 = 0
  }

  private let runs = Mutex<[Run]>([])
  private let terminated = Mutex<Set<Int>>([])
  private let receivedSamples = Mutex<[Int: Int]>([:])
  private let finishedAudio = Mutex<Set<Int>>([])

  /// `run` 番目の認識が受け取った音声のサンプル数
  func sampleCount(of run: Int) -> Int {
    receivedSamples.withLock { $0[run] ?? 0 }
  }

  /// `run` 番目の認識の音声が終わったか（録音の終わり）
  func isAudioFinished(_ run: Int) -> Bool {
    finishedAudio.withLock { $0.contains(run) }
  }

  /// `run` 番目の認識のストリームが閉じたか（受け手の破棄・終端イベント）
  func isTerminated(_ run: Int) -> Bool {
    terminated.withLock { $0.contains(run) }
  }

  var runCount: Int {
    runs.withLock { $0.count }
  }

  func session(of run: Int) -> SessionID? {
    runs.withLock { $0.indices.contains(run) ? $0[run].session : nil }
  }

  func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    let index = runs.withLock { runs in
      runs.append(Run(session: session, continuation: continuation))
      return runs.count - 1
    }
    continuation.onTermination = { [weak self] _ in
      self?.terminated.withLock { _ = $0.insert(index) }
    }
    // 音声は数えて読み捨てる（読まないと録音側に溜まる）
    Task { [weak self] in
      for await chunk in audio {
        self?.receivedSamples.withLock { $0[index, default: 0] += chunk.samples.count }
      }
      self?.finishedAudio.withLock { _ = $0.insert(index) }
    }
    return stream
  }

  /// `run` 番目の認識のストリームに、任意のセッション・順序番号のイベントを流す（契約に反する遅延イベントの再現）
  func sendRaw(_ event: RecognitionEvent, to run: Int) {
    let continuation = runs.withLock { $0.indices.contains(run) ? $0[run].continuation : nil }
    continuation?.yield(event)
  }

  /// `run` 番目の認識にイベントを流す
  func send(_ kind: RecognitionEvent.Kind, to run: Int) {
    let target = runs.withLock { runs -> (Run, UInt64)? in
      guard runs.indices.contains(run) else { return nil }
      let sequence = runs[run].nextSequence
      runs[run].nextSequence += 1
      return (runs[run], sequence)
    }
    guard let (target, sequence) = target else { return }
    target.continuation.yield(
      RecognitionEvent(sessionID: target.session, sequence: sequence, kind: kind))
    if kind.isTerminal {
      target.continuation.finish()
    }
  }
}

/// 使用許可を尋ねたまま、テストが答えるまで待つマイク（PERM-01）。
final class GatedMicrophoneAccess: MicrophoneAccess {
  private let pending = Mutex<CheckedContinuation<Bool, Never>?>(nil)

  var isAsking: Bool {
    pending.withLock { $0 != nil }
  }

  func authorization() async -> MicrophoneAuthorization {
    .notDetermined
  }

  func requestAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      pending.withLock { $0 = continuation }
    }
  }

  func answer(_ granted: Bool) {
    let continuation = pending.withLock { pending in
      defer { pending = nil }
      return pending
    }
    continuation?.resume(returning: granted)
  }
}

/// 条件が満たされるまで待つ。非同期の処理（録音の開始・認識・挿入）が進むのを待つために使う
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<2_000 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return condition()
}

/// 除外アプリの保存値の代わり。テストの途中で値を変え、開始ごとに読み直すことを確かめる
@MainActor
final class ExcludedAppsBox {
  var apps: Set<String> = []
}
