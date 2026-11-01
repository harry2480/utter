// #233 の待機セッション方式の試作（本体アプリ側）。本番コードではない。
// 待機中はオーディオセッションを保ち、キーボードの合図で録音・認識・整形をして共有結果に保存する。
// 音声はメモリ上で認識器に渡すだけで、ファイル・App Group・ログに出さない。

import AVFoundation
import Observation
import Speech
import Synchronization
import UIKit
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

@MainActor
@Observable
final class VoiceSessionController {
  /// 待機の保ち方。どちらで裏の録音を始められるかを比べる
  enum StandbyMode: String, CaseIterable, Identifiable {
    /// 待機中もマイクの入力を開いたままにし、合図までの音声は捨てる（マイクの表示が出続ける）
    case holdMicrophone
    /// 待機中は無音を再生してアプリを保ち、合図でマイクの入力を開く（裏で入力を始められるかが未知）
    case silentPlayback
    /// マイクを開いたまま、合図までは入力をミュートする（AVAudioApplication.setInputMuted）。
    /// ミュート中にマイクの表示（オレンジの点）が消えるかを見る
    case mutedMicrophone

    var id: String { rawValue }
    var label: String {
      switch self {
      case .holdMicrophone: "マイクを開いたまま待機"
      case .silentPlayback: "無音を再生して待機"
      case .mutedMicrophone: "マイクを開いてミュートで待機"
      }
    }
  }

  /// 既定はマイクを開いたまま。無音の再生だけで待つ方式は、裏でマイクを開けなかった（avfaudio 2003329396, 2026-10-31）
  /// UI テストでは起動引数 -ProbeStandbyMode <rawValue> で選ぶ
  var mode: StandbyMode =
    UserDefaults.standard.string(forKey: "ProbeStandbyMode").flatMap(StandbyMode.init(rawValue:))
    ?? .holdMicrophone

  /// マイクの入力を開いたまま待つ方式か
  private var keepsInputOpen: Bool { mode != .silentPlayback }
  /// 合図がなければ待機を終える分数。0 なら終えない
  /// UI テストでは起動引数 -ProbeIdleTimeoutMinutes 0 で終えないようにする
  var idleTimeoutMinutes =
    UserDefaults.standard.string(forKey: "ProbeIdleTimeoutMinutes").flatMap(Int.init) ?? 5
  private(set) var phase: VoiceHostState.Phase = .off
  private(set) var lines: [String] = []
  private(set) var lastTimings: String = "まだありません"

  @ObservationIgnored private var engine: AVAudioEngine?
  @ObservationIgnored private var player: AVAudioPlayerNode?
  @ObservationIgnored private var inputTapInstalled = false
  @ObservationIgnored private let sink = ChunkSink()
  @ObservationIgnored private var activeSessionID: SessionID?
  @ObservationIgnored private var recognition: Task<RecognitionOutcome, Never>?
  @ObservationIgnored private var heartbeat: Task<Void, Never>?
  /// 録音中だけ、音量を 0.1 秒ごとに App Group へ書く（キーボードの波形の表示用）
  @ObservationIgnored private var levelWriter: Task<Void, Never>?
  @ObservationIgnored private var lastSequence: Int64 = 0
  /// 今の録音を始めた時刻（上限の判定に使う）
  @ObservationIgnored private var captureStartedAt: Date?
  /// 1回の録音の上限。UI テストでは起動引数 -ProbeMaxCaptureSeconds で短くする
  static let maxCaptureSeconds: TimeInterval =
    UserDefaults.standard.string(forKey: "ProbeMaxCaptureSeconds").flatMap(Double.init) ?? 120
  @ObservationIgnored private var lastActivity = Date()
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []
  @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  @ObservationIgnored private let recognizer = SpeechAnalyzerRecognizer()
  @ObservationIgnored private let refiner = LocalBasicRefiner()

  init() {
    VoiceSignal.startForwarding()
    observers.append(
      NotificationCenter.default.addObserver(
        forName: VoiceSignal.command.localName, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.handleCommandSignal() }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let began =
          (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
          == AVAudioSession.InterruptionType.began.rawValue
        MainActor.assumeIsolated { self?.handleInterruption(began: began) }
      })
  }

  // MARK: 待機

  func startStandby() async {
    guard phase == .off else { return }
    guard await AVAudioApplication.requestRecordPermission() else {
      note("マイクの許可がない")
      return
    }
    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
      _ = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
      }
    }
    // モデルの確保はアプリごと。このアプリで確保していなければ、ここで確保・取得する
    let assets = SpeechAnalyzerAssets()
    let availability = await assets.availability()
    note("音声認識のモデル: \(availability)")
    if availability != .installed {
      do {
        try await assets.install()
        note("音声認識のモデル: \(await assets.availability())")
      } catch {
        note("モデルを取得できない: \(error)")
        return
      }
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord, mode: .default,
        options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
      try session.setActive(true)
      try startEngine(withInput: keepsInputOpen)
      setInputMuted(true)
    } catch {
      note("待機を始められない: \(Self.summary(error))")
      stopEngine()
      return
    }
    lastSequence =
      VoiceStore.read(VoiceCommand.self, from: VoiceStore.commandFileName)?.sequence ?? 0
    lastActivity = Date()
    setPhase(.standby, sessionID: nil)
    VoiceStore.appendEvent(source: "host", name: "standbyStarted", detail: mode.rawValue)
    note("待機を始めた（\(mode.label)）")
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        self?.tick()
      }
    }
  }

  func stopStandby(reason: String) {
    heartbeat?.cancel()
    heartbeat = nil
    levelWriter?.cancel()
    levelWriter = nil
    sink.finish()
    recognition?.cancel()
    recognition = nil
    activeSessionID = nil
    stopEngine()
    setInputMuted(false)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    setPhase(.off, sessionID: nil, detail: reason)
    VoiceStore.appendEvent(source: "host", name: "standbyStopped", detail: reason)
    note("待機を終えた（\(reason)）")
  }

  private func tick() {
    guard phase != .off else { return }
    // 合図の取りこぼしに備えて、Darwin 通知がなくても読み直す
    handleCommandSignal()
    // キーボードが落ちたなどで停止の合図が来ないときの最後の保険。上限を超えた録音は捨てる
    if phase == .recording, let captureStartedAt,
      Date().timeIntervalSince(captureStartedAt) > Self.maxCaptureSeconds
    {
      abandonCapture(nil, reason: "録音が\(Int(Self.maxCaptureSeconds))秒を超えた")
    }
    if idleTimeoutMinutes > 0, phase == .standby || phase == .done || phase == .failed,
      Date().timeIntervalSince(lastActivity) > Double(idleTimeoutMinutes * 60)
    {
      stopStandby(reason: "無操作で終了")
      return
    }
    writeState(detail: nil)
  }

  // MARK: 合図

  private func handleCommandSignal() {
    guard phase != .off,
      let command = VoiceStore.read(VoiceCommand.self, from: VoiceStore.commandFileName),
      command.sequence > lastSequence
    else { return }
    lastSequence = command.sequence
    lastActivity = Date()
    VoiceStore.appendEvent(
      source: "host", name: "\(command.action.rawValue)Received", sessionID: command.sessionID,
      detail: UIApplication.shared.applicationState == .active ? "foreground" : "background")
    switch command.action {
    case .start: beginCapture(command.sessionID)
    case .stop: Task { await finishCapture(command.sessionID) }
    case .cancel: abandonCapture(command.sessionID, reason: "キーボードが閉じられた")
    }
  }

  /// 録音中のセッションを止めて捨てる（認識の結果も保存しない）。`sessionID` が nil なら、今のセッションを捨てる
  private func abandonCapture(_ sessionID: SessionID?, reason: String) {
    guard phase == .recording, let active = activeSessionID,
      sessionID == nil || sessionID == active
    else { return }
    levelWriter?.cancel()
    levelWriter = nil
    sink.finish()
    recognition?.cancel()
    recognition = nil
    activeSessionID = nil
    captureStartedAt = nil
    _ = sink.takeStatistics()
    setInputMuted(true)
    VoiceStore.appendEvent(
      source: "host", name: "captureAbandoned", sessionID: active, detail: reason)
    note("録音を捨てた（\(reason)）")
    // キーボードが開いていれば失敗として知らせる（録音中の表示のまま止まらないように）。失敗の状態からも次の録音を始められる
    setPhase(.failed, sessionID: active, detail: reason)
  }

  private func beginCapture(_ sessionID: SessionID) {
    // 取り消しの合図を取りこぼして古い録音が残っていたら、捨ててから始める
    if phase == .recording, activeSessionID != sessionID {
      abandonCapture(nil, reason: "別のセッションが始まった")
    }
    guard phase == .standby || phase == .done || phase == .failed else {
      note("録音を始められない状態（\(phase.rawValue)）")
      return
    }
    if mode == .silentPlayback {
      do {
        try startEngine(withInput: true)
      } catch {
        // 裏でマイクの入力を開けなかった。この方式の成否そのもの
        setPhase(.failed, sessionID: sessionID, detail: "入力を開けない: \(Self.summary(error))")
        VoiceStore.appendEvent(
          source: "host", name: "inputStartFailed", sessionID: sessionID,
          detail: Self.summary(error))
        return
      }
    }
    setInputMuted(false)
    activeSessionID = sessionID
    let stream = sink.open(sessionID: sessionID)
    let events = recognizer.recognize(stream, session: sessionID)
    recognition = Task {
      var finalText = ""
      for await event in events {
        switch event.kind {
        case .completed(let text): return .text(text)
        case .failed(let error): return .failed(String(describing: error))
        case .confirmed(let text): finalText += text
        case .partial: break
        }
      }
      return .text(finalText)
    }
    setPhase(.recording, sessionID: sessionID)
    captureStartedAt = Date()
    VoiceStore.appendEvent(source: "host", name: "captureStarted", sessionID: sessionID)
    levelWriter?.cancel()
    levelWriter = Task { [sink] in
      while !Task.isCancelled {
        try? VoiceStore.write(
          VoiceLevel(sessionID: sessionID, levels: sink.recentLevels(), at: Date()),
          to: VoiceStore.levelFileName)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func finishCapture(_ sessionID: SessionID) async {
    guard activeSessionID == sessionID, let recognition else { return }
    captureStartedAt = nil
    levelWriter?.cancel()
    levelWriter = nil
    sink.finish()
    setPhase(.processing, sessionID: sessionID)
    setInputMuted(true)
    // 認識・整形が裏で中断しないよう、有限時間の実行を求める（オーディオセッションも保ったまま）
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "voice-finish") {
      [weak self] in
      MainActor.assumeIsolated { self?.endBackgroundTask() }
    }
    defer { endBackgroundTask() }
    if mode == .silentPlayback {
      // マイクの表示を消すため、入力を閉じて無音の再生だけに戻す
      try? startEngine(withInput: false)
    }
    let outcome = await recognition.value
    // 待っている間に待機の終了・割り込みが入っていたら、結果を保存せず状態も変えない
    guard phase == .processing, activeSessionID == sessionID else {
      _ = sink.takeStatistics()
      VoiceStore.appendEvent(
        source: "host", name: "resultDiscarded", sessionID: sessionID, detail: phase.rawValue)
      return
    }
    self.recognition = nil
    activeSessionID = nil
    let audio = sink.takeStatistics()
    let audioDetail = String(
      format: "音声 %.1f秒・最大音量 %.3f", audio.seconds, audio.peak)
    VoiceStore.appendEvent(
      source: "host", name: "recognized", sessionID: sessionID, detail: audioDetail)
    let text: String
    switch outcome {
    case .failed(let reason):
      setPhase(.failed, sessionID: sessionID, detail: "認識に失敗: \(reason)（\(audioDetail)）")
      return
    case .text(let recognized):
      guard !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        setPhase(.failed, sessionID: sessionID, detail: "認識結果が空（\(audioDetail)）")
        return
      }
      text = recognized
    }
    let refined = refiner.refine(RefinementRequest(text: text, mode: .natural))
    VoiceStore.appendEvent(source: "host", name: "refined", sessionID: sessionID)
    guard let store = VoiceStore.resultStore() else {
      setPhase(.failed, sessionID: sessionID, detail: "共有結果の置き場を開けない")
      return
    }
    do {
      try await store.save(
        SharedResult(sessionID: sessionID, text: refined, createdAt: Date()), expectedRevision: nil)
    } catch {
      setPhase(.failed, sessionID: sessionID, detail: "保存できない: \(Self.summary(error))")
      return
    }
    VoiceStore.appendEvent(source: "host", name: "saved", sessionID: sessionID)
    setPhase(.done, sessionID: sessionID)
    lastActivity = Date()
    exportEvents()
  }

  /// ミュートで待つ方式のときだけ、マイクの入力をミュートする・戻す
  private func setInputMuted(_ muted: Bool) {
    guard mode == .mutedMicrophone else { return }
    do {
      try AVAudioApplication.shared.setInputMuted(muted)
      VoiceStore.appendEvent(source: "host", name: muted ? "inputMuted" : "inputUnmuted")
    } catch {
      note("ミュートを\(muted ? "かけられない" : "外せない"): \(Self.summary(error))")
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  private func handleInterruption(began: Bool) {
    VoiceStore.appendEvent(
      source: "host", name: began ? "interruptionBegan" : "interruptionEnded",
      sessionID: activeSessionID)
    guard phase != .off else { return }
    if began {
      if let activeSessionID {
        levelWriter?.cancel()
        levelWriter = nil
        sink.finish()
        setPhase(.failed, sessionID: activeSessionID, detail: "割り込みで録音が止まった")
        recognition?.cancel()
        recognition = nil
        self.activeSessionID = nil
      }
      note("割り込みが始まった")
    } else {
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        try startEngine(withInput: keepsInputOpen)
        setInputMuted(true)
        setPhase(.standby, sessionID: nil)
        note("割り込みの後に待機へ戻った")
      } catch {
        stopStandby(reason: "割り込みの後に再開できない: \(Self.summary(error))")
      }
    }
  }

  // MARK: エンジン

  /// エンジンを作り直す。`withInput` ならマイクの入力を開き、合図の間だけ認識器へ流す
  private func startEngine(withInput: Bool) throws {
    stopEngine()
    let engine = AVAudioEngine()
    // 無音を鳴らし続けて、裏でもアプリを保つ（audio のバックグラウンドモード）
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
    engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
    if withInput {
      let input = engine.inputNode
      let inputFormat = input.outputFormat(forBus: 0)
      guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
        let targetFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
      else { throw ProbeAudioError.microphoneUnavailable }
      input.installTap(
        onBus: 0, bufferSize: 4096, format: inputFormat,
        block: Self.makeTapBlock(converter: converter, outputFormat: targetFormat, sink: sink))
      inputTapInstalled = true
    }
    engine.prepare()
    try engine.start()
    if let silence = AVAudioPCMBuffer(
      pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outputFormat.sampleRate))
    {
      silence.frameLength = silence.frameCapacity
      player.scheduleBuffer(silence, at: nil, options: .loops)
      player.play()
    }
    self.engine = engine
    self.player = player
  }

  private func stopEngine() {
    if let engine {
      if inputTapInstalled { engine.inputNode.removeTap(onBus: 0) }
      player?.stop()
      engine.stop()
    }
    inputTapInstalled = false
    engine = nil
    player = nil
  }

  /// タップのクロージャは録音のスレッドで呼ばれるため、隔離のない static 関数で作る
  private nonisolated static func makeTapBlock(
    converter: AVAudioConverter, outputFormat: AVAudioFormat, sink: ChunkSink
  ) -> AVAudioNodeTapBlock {
    let sampleRate = Int(outputFormat.sampleRate)
    return { buffer, _ in
      // 合図の間だけ流す。待機中の音声はここで捨てる
      guard sink.isOpen,
        let converted = ProbeAudioConversion.convert(buffer, using: converter, to: outputFormat),
        let channel = converted.floatChannelData?[0]
      else { return }
      let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
      sink.yield(AudioChunk(samples: samples, sampleRate: sampleRate))
    }
  }

  // MARK: 状態

  private func setPhase(_ phase: VoiceHostState.Phase, sessionID: SessionID?, detail: String? = nil)
  {
    self.phase = phase
    writeState(detail: detail, sessionID: sessionID)
    if phase == .failed {
      // 失敗の理由（「認識結果が空」など。発話の本文は入らない）を計測の記録にも残す
      VoiceStore.appendEvent(source: "host", name: "failed", sessionID: sessionID, detail: detail)
    }
    VoiceSignal.hostState.post()
    if let detail { note("\(phase.rawValue): \(detail)") }
  }

  @ObservationIgnored private var stateSessionID: SessionID?

  private func writeState(detail: String?, sessionID: SessionID? = nil) {
    if sessionID != nil || phase == .off || phase == .standby { stateSessionID = sessionID }
    try? VoiceStore.write(
      VoiceHostState(phase: phase, sessionID: stateSessionID, updatedAt: Date(), detail: detail),
      to: VoiceStore.hostStateFileName)
  }

  private func note(_ message: String) {
    lines.insert("\(ProbeTime.format(Date())) \(message)", at: 0)
    if lines.count > 100 { lines.removeLast(lines.count - 100) }
  }

  /// 計測の記録を Documents にも写す（Mac から devicectl で取り出せるように）。本文は含まない
  func exportEvents() {
    guard let data = VoiceStore.eventsData() else { return }
    let directory = URL.documentsDirectory.appending(
      path: "ProbeOutput", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appending(path: VoiceStore.eventsFileName), options: .atomic)
    lastTimings = VoiceTimings.summary(from: data)
  }

  func clearEvents() {
    VoiceStore.clearEvents()
    lastTimings = "まだありません"
    note("計測の記録を消した")
  }

  static func summary(_ error: any Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code)"
  }
}

enum RecognitionOutcome: Sendable {
  case text(String)
  case failed(String)
}

enum ProbeAudioError: Error {
  case microphoneUnavailable
}

/// 録音のスレッドから認識器へ音声を渡す口。合図の間だけ開く
final class ChunkSink: Sendable {
  private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)

  var isOpen: Bool { continuation.withLock { $0 != nil } }

  func open(sessionID: SessionID) -> AsyncStream<AudioChunk> {
    let (stream, newContinuation) = AsyncStream<AudioChunk>.makeStream()
    statistics.withLock { $0 = (0, 16_000, 0) }
    levels.withLock { $0 = [] }
    continuation.withLock {
      $0?.finish()
      $0 = newContinuation
    }
    return stream
  }

  /// 届いた音声の量と最大音量（原因の切り分け用。音声そのものは残さない）
  private let statistics = Mutex<(samples: Int, sampleRate: Int, peak: Float)>((0, 16_000, 0))

  /// 直近の音量（0〜1）。波形の表示に使う
  private let levels = Mutex<[Float]>([])

  func recentLevels() -> [Float] {
    levels.withLock { $0 }
  }

  func yield(_ chunk: AudioChunk) {
    let peak = chunk.samples.reduce(Float(0)) { max($0, abs($1)) }
    let meanSquare =
      chunk.samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(chunk.samples.count, 1))
    // -50dB〜-10dB を 0〜1 に写す
    let decibels = 10 * log10(max(meanSquare, 1e-10))
    let level = min(1, max(0, (decibels + 50) / 40))
    levels.withLock {
      $0.append(level)
      if $0.count > 7 { $0.removeFirst($0.count - 7) }
    }
    statistics.withLock {
      $0 = ($0.samples + chunk.samples.count, chunk.sampleRate, max($0.peak, peak))
    }
    continuation.withLock { _ = $0?.yield(chunk) }
  }

  func takeStatistics() -> (seconds: Double, peak: Float) {
    statistics.withLock {
      defer { $0 = (0, 16_000, 0) }
      return (Double($0.samples) / Double(max($0.sampleRate, 1)), $0.peak)
    }
  }

  func finish() {
    continuation.withLock {
      $0?.finish()
      $0 = nil
    }
  }
}

/// Apps/iOS の AudioEngineRecorder と同じ変換（検証用に写したもの）
enum ProbeAudioConversion {
  static func convert(
    _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
      let input = PendingInput(copying: buffer)
    else { return nil }
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      guard let buffer = input.take() else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0 else { return nil }
    return output
  }
}

private final class PendingInput: Sendable {
  private let buffer: Mutex<AVAudioPCMBuffer?>

  init?(copying source: AVAudioPCMBuffer) {
    guard let sourceChannels = source.floatChannelData else { return nil }
    let frameCount = Int(source.frameLength)
    guard frameCount > 0 else { return nil }
    let channels = (0..<Int(source.format.channelCount)).map {
      Array(UnsafeBufferPointer(start: sourceChannels[$0], count: frameCount))
    }
    guard
      let copy = Self.makeBuffer(format: source.format, channels: channels, frameCount: frameCount)
    else { return nil }
    buffer = Mutex(copy)
  }

  func take() -> AVAudioPCMBuffer? {
    buffer.withLock { value in
      defer { value = nil }
      return value
    }
  }

  private static func makeBuffer(
    format: AVAudioFormat, channels: [[Float]], frameCount: Int
  ) -> sending AVAudioPCMBuffer? {
    guard
      let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
      let destination = copy.floatChannelData
    else { return nil }
    for (index, samples) in channels.enumerated() {
      samples.withUnsafeBufferPointer { samples in
        guard let base = samples.baseAddress else { return }
        destination[index].update(from: base, count: frameCount)
      }
    }
    copy.frameLength = AVAudioFrameCount(frameCount)
    return copy
  }
}

/// 計測の記録から、直近のセッションの区間をまとめる（画面表示用）
enum VoiceTimings {
  static func summary(from data: Data) -> String {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let events = data.split(separator: 0x0A).compactMap {
      try? decoder.decode(VoiceEvent.self, from: Data($0))
    }
    guard let last = events.last(where: { $0.sessionID != nil })?.sessionID else {
      return "まだありません"
    }
    let session = events.filter { $0.sessionID == last }
    func time(_ name: String) -> Date? { session.first { $0.name == name }?.at }
    func span(_ from: String, _ to: String) -> String {
      guard let a = time(from), let b = time(to) else { return "-" }
      return String(format: "%.0fms", b.timeIntervalSince(a) * 1000)
    }
    return [
      "タップ→本体が受信: \(span("tapStart", "startReceived"))",
      "タップ→録音開始: \(span("tapStart", "captureStarted"))",
      "停止タップ→認識完了: \(span("tapStop", "recognized"))",
      "停止タップ→保存: \(span("tapStop", "saved"))",
      "停止タップ→挿入: \(span("tapStop", "inserted"))",
    ].joined(separator: "\n")
  }
}
