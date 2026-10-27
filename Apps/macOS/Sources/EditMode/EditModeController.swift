import Observation
import UtterAI
import UtterCore
import UtterSpeech

/// Edit Mode の間、録音のセッションを始めないようにする（本番は `SessionCoordinator`）。
@MainActor
protocol EditModeSessionGate: AnyObject {
  /// 待機中なら新しいセッションを始めないようにして `true`。録音のセッション中・起動時の復旧中なら何もせず `false`
  func suspendIfIdle() -> Bool
  /// `suspendIfIdle()` で止めた開始操作を受け付け直す
  func resume()
}

extension SessionCoordinator: EditModeSessionGate {}

/// Edit Mode の1回の流れを、録音のセッションと1つずつ調停する（AC-14, 2.2節）。
///
/// ショートカット → 選択範囲の取得 → 音声指示の録音・STT → 編集案の取得 → 差分プレビュー → 確定 / キャンセル → 元に戻す。
/// 選択範囲の読み取り・送信・置き換えは `EditModeCoordinator` に任せ、ここは録音・STT と段階の移り変わりだけを持つ。
///
/// - 音声認識のエンジンが選ばれていない（`recognizer == nil`）なら、録音のセッションと同じく
///   「音声認識が設定されていません」を出し、選択範囲を読まずにマイクも開かない
/// - 始めるときに `EditModeSessionGate.suspendIfIdle()` で録音のセッションを止める。録音のセッション中（起動時の復旧中を含む）は
///   Edit を始めず、Edit の間（確定・キャンセル・元に戻すまで）は録音のセッションを始めない。録音と STT Worker は同時に1つしか使わない
/// - 録音中にもう一度ショートカットを押すと録音を止め、認識したテキストを音声指示として送る。差分プレビューの確認中に押すと、
///   同じ選択テキストへの音声指示をやり直す
/// - 音声指示の長さは `maxInstructionDuration` までで、超えたら録音を止めてそこまでの音声で認識する
/// - 音声指示を録音・認識できない、または編集案を得られなければ通知し、確認中の編集案がなければ Edit を終える（選択範囲は変えない）
/// - 音声と認識テキスト（音声指示）はログに出さず、保存もしない（一時音声の保存と認識のやり直しは録音のセッションだけが行う）
@MainActor
@Observable
final class EditModeController {
  /// Edit Mode の段階
  enum Phase: Hashable, Sendable {
    /// 待機中。録音のセッションを止めていない
    case idle
    /// 音声指示を録音している
    case listening
    /// 録音を止め、認識の結果を待っている
    case recognizing
    /// 編集案を待っている
    case requesting
    /// 差分プレビューで確定かキャンセルを待っている
    case reviewing
    /// 置き換え・元に戻すを行っている
    case replacing
  }

  /// 現在の段階。メニューの表示に使う
  private(set) var phase: Phase = .idle
  /// 元に戻せる Edit があるか。メニューの表示に使う
  private(set) var canUndo = false

  @ObservationIgnored private let coordinator: EditModeCoordinator
  @ObservationIgnored private let recorder: any AudioRecorder
  @ObservationIgnored private let recognizer: (any SpeechRecognizer)?
  @ObservationIgnored private let gate: any EditModeSessionGate
  @ObservationIgnored private let presenter: any EditModePresenting
  @ObservationIgnored private let maxInstructionDuration: Duration
  @ObservationIgnored private let makeSessionID: @Sendable () -> SessionID
  /// 音声指示の録音・認識・送信のタスク
  @ObservationIgnored private var runTask: Task<Void, Never>?
  /// 音声指示の試行の番号。キャンセル・やり直しで進め、古い試行の結果を捨てる
  @ObservationIgnored private var attempt = 0
  /// 録音のセッションを止めているか（`gate.resume()` を1回だけ呼ぶため）
  @ObservationIgnored private var holdsGate = false

  /// 音声指示の長さの上限の既定値（仮置き）。指示は短い文のため、録音の最大録音時間より短くする
  nonisolated static let defaultMaxInstructionDuration: Duration = .seconds(60)

  /// - Parameters:
  ///   - coordinator: 選択範囲の読み取り・送信・差分プレビュー・置き換え。`presenter` と同じ表示先を使う
  ///   - recorder: 録音。録音のセッションと同じものを渡す（同時に1つしか録音しないため）
  ///   - recognizer: 音声認識。エンジンが選ばれていなければ `nil`。録音のセッションと同じ STT Worker を使う
  ///   - gate: Edit の間、録音のセッションを止める
  ///   - presenter: 通知と進行中の表示
  ///   - maxInstructionDuration: 音声指示の長さの上限
  init(
    coordinator: EditModeCoordinator,
    recorder: any AudioRecorder,
    recognizer: (any SpeechRecognizer)?,
    gate: any EditModeSessionGate,
    presenter: any EditModePresenting,
    maxInstructionDuration: Duration = EditModeController.defaultMaxInstructionDuration,
    makeSessionID: @escaping @Sendable () -> SessionID = { SessionID() }
  ) {
    self.coordinator = coordinator
    self.recorder = recorder
    self.recognizer = recognizer
    self.gate = gate
    self.presenter = presenter
    self.maxInstructionDuration = maxInstructionDuration
    self.makeSessionID = makeSessionID
  }

  /// Edit をキャンセルできるか（録音中〜確認中）
  var canCancel: Bool {
    switch phase {
    case .listening, .recognizing, .requesting, .reviewing: true
    case .idle, .replacing: false
    }
  }

  // MARK: - 操作

  /// ショートカットが押された。待機中なら始め、録音中なら止め、確認中なら音声指示をやり直す。
  /// 認識中・応答待ち・置き換え中は無視する
  func toggle() {
    switch phase {
    case .idle: start()
    case .listening: stopListening()
    case .reviewing: listen()
    case .recognizing, .requesting, .replacing: break
    }
  }

  /// 確定せずに Edit を終える。選択範囲は変えない。録音中なら録音を止めて音声を捨てる
  func cancel() {
    guard canCancel else { return }
    abortInstruction()
    coordinator.cancel()
    finish()
  }

  /// 確認中の編集案で確定し、選択範囲を置き換える。音声指示をやり直している途中なら、それを捨てて確定する
  func commit() async {
    switch phase {
    case .reviewing:
      break
    case .listening, .recognizing, .requesting:
      guard coordinator.hasProposal else { return }
      abortInstruction()
    case .idle, .replacing:
      return
    }
    phase = .replacing
    presenter.showStatus(nil)
    await coordinator.commit()
    finish()
  }

  /// 直前に確定した Edit を元に戻す。録音のセッション中は行わない
  func undo() async {
    guard phase == .idle, coordinator.canUndo else { return }
    guard gate.suspendIfIdle() else {
      presenter.showNotice(.sessionInProgress)
      return
    }
    holdsGate = true
    phase = .replacing
    await coordinator.undo()
    finish()
  }

  // MARK: - 流れ

  private func start() {
    // 音声認識が使えないのに選択範囲を読んだりマイクを開いたりしない
    guard recognizer != nil else {
      presenter.showNotice(.speechRecognitionNotConfigured)
      return
    }
    guard gate.suspendIfIdle() else {
      presenter.showNotice(.sessionInProgress)
      return
    }
    holdsGate = true
    // 始められなければ `EditModeCoordinator` が理由を通知する
    guard coordinator.begin() == nil else {
      finish()
      return
    }
    // 始めると、前に確定した Edit は元に戻せなくなる
    canUndo = coordinator.canUndo
    listen()
  }

  /// 音声指示の録音を始める
  private func listen() {
    guard let recognizer else { return }
    attempt += 1
    let current = attempt
    phase = .listening
    presenter.showStatus(.listening)
    runTask = Task { [weak self] in
      await self?.run(attempt: current, recognizer: recognizer)
    }
  }

  /// 録音を止め、そこまでの音声で認識する
  private func stopListening() {
    guard phase == .listening else { return }
    phase = .recognizing
    presenter.showStatus(.recognizing)
    let recorder = recorder
    Task { await recorder.stop() }
  }

  private func run(attempt current: Int, recognizer: any SpeechRecognizer) async {
    let recording: AudioRecording
    do {
      recording = try await startRecorder()
    } catch {
      guard isCurrent(current) else { return }
      switch error {
      case .cancelled:
        // 録音が始まる前に止められた。音声がないため、通知せずに戻る
        instructionEnded(notice: nil)
      case .microphoneAccessDenied, .microphoneAccessRestricted:
        instructionEnded(notice: .instructionNotRecorded(.microphoneAccessDenied))
      case .alreadyRecording, .inputDeviceUnavailable, .startFailed:
        instructionEnded(notice: .instructionNotRecorded(.recordingFailed))
      }
      return
    }
    guard isCurrent(current) else {
      // 始めるのを待つ間にキャンセルされた
      await recorder.stop()
      return
    }
    if phase == .recognizing {
      // 始めるのを待つ間に止められた。止める操作が録音の開始より先に届いていても、ここで確実に止める
      await recorder.stop()
    }

    let session = makeSessionID()
    var filter = RecognitionEventFilter()
    filter.begin(session)
    var text: String?
    for await event in recognizer.recognize(recording.chunks, session: session) {
      guard isCurrent(current) else { break }
      guard filter.accept(event) == nil else { continue }
      if case .completed(let value) = event.kind {
        text = value
        break
      }
      if case .failed = event.kind { break }
    }
    // 認識が先に終わった（失敗・上限）ときも、マイクを開いたままにしない
    await recorder.stop()
    guard isCurrent(current) else { return }
    guard let text else {
      instructionEnded(notice: .instructionNotRecorded(.recognitionFailed))
      return
    }
    // 空の指示は送らない（設定・予算を読む前に止める）
    guard !text.allSatisfy(\.isWhitespace) else {
      instructionEnded(notice: .notEdited(.emptyInstruction))
      return
    }

    phase = .requesting
    presenter.showStatus(.requesting)
    let result = await coordinator.submit(instruction: text)
    guard isCurrent(current) else { return }
    runTask = nil
    if result == .proposed {
      phase = .reviewing
      presenter.showStatus(nil)
    } else {
      // 通知は `EditModeCoordinator` が出している
      instructionEnded(notice: nil)
    }
  }

  /// 音声指示から編集案を得られなかった。確認中の編集案があれば確認に戻り、なければ Edit を終える
  private func instructionEnded(notice: EditModeNotice?) {
    runTask = nil
    if let notice {
      presenter.showNotice(notice)
    }
    if coordinator.hasProposal {
      phase = .reviewing
      presenter.showStatus(nil)
    } else {
      coordinator.cancel()
      finish()
    }
  }

  /// 進行中の音声指示の録音・認識・送信をやめる。結果は捨てる
  private func abortInstruction() {
    attempt += 1
    runTask?.cancel()
    runTask = nil
    switch phase {
    case .listening, .recognizing:
      let recorder = recorder
      Task { await recorder.stop() }
    case .idle, .requesting, .reviewing, .replacing:
      break
    }
  }

  /// 待機に戻り、録音のセッションを始められるようにする
  private func finish() {
    phase = .idle
    runTask = nil
    presenter.showStatus(nil)
    canUndo = coordinator.canUndo
    if holdsGate {
      holdsGate = false
      gate.resume()
    }
  }

  private func isCurrent(_ value: Int) -> Bool {
    value == attempt && phase != .idle
  }

  /// 録音を始める。直前の録音のセッションの停止が録音側に遅れて届いて録音中と言われたら、それを止めてから1回だけやり直す
  private func startRecorder() async throws(AudioRecorderError) -> AudioRecording {
    do {
      return try await recorder.start(buffer: instructionBuffer)
    } catch .alreadyRecording {
      await recorder.stop()
      return try await recorder.start(buffer: instructionBuffer)
    }
  }

  /// 音声指示の音声バッファの上限（PCM16・16kHz 換算）
  private var instructionBuffer: AudioStreamBuffer {
    let components = maxInstructionDuration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    let bytes = (seconds * Double(AudioRecordingPipeline.defaultSampleRate * 2)).rounded(.up)
    return AudioStreamBuffer(maxBytes: bytes >= Double(Int.max) ? Int.max : max(1, Int(bytes)))
  }
}
