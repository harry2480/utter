import AVFoundation
import AppKit
import UtterCore
import UtterSpeech

/// `AVAudioEngine` でマイクから録音する macOS の `AudioRecorder`（REC-04, REC-05）。
///
/// - 録音を始めるたびに使用許可を確かめ、未確認なら要求する。許可がなければ録音しない（PERM-01）
/// - 入力機器の音声をモノラルにまとめ（`AudioDownmix`）、16kHz に変換して（`MonoResampler`）、
///   `AudioRecordingPipeline` で 100ms ごとのチャンクにして上限つきで流す（REC-05）
/// - 次の通知で録音を止め、`AudioRecordingEnd.reason` の `.interrupted(_:)` で知らせる。自動で再開しない。
///   値の対応は docs/アーキテクチャ.md の「macOS の録音（AVAudioEngine）」を参照
///   - `AVAudioEngineConfigurationChange`（入力機器の切断・既定の入力機器の変更・形式の変更。エンジンは止まっている）
///   - `NSWorkspace.willSleepNotification`（スリープ）
/// - 音声はメモリ上で流すだけで、ファイルやログには出さない
actor AVAudioEngineRecorder: AudioRecorder {
  private let microphone: any MicrophoneAccess
  private var phase: Phase = .idle
  private var lastAttempt: UInt64 = 0

  private enum Phase {
    case idle
    /// 使用許可の確認・要求を待っている
    case starting(attempt: UInt64)
    case recording(ActiveRecording)
  }

  private struct ActiveRecording {
    let attempt: UInt64
    let engine: AVAudioEngine
    let resampler: MonoResampler
    let pipeline: AudioRecordingPipeline
    let configurationObserver: any NSObjectProtocol
    let sleepObserver: any NSObjectProtocol
  }

  /// 1回のコールバックで受け取るフレーム数の目安（OS が変えることがある）
  private static let tapBufferSize: AVAudioFrameCount = 4_096

  init(microphone: any MicrophoneAccess = AVMicrophoneAccess()) {
    self.microphone = microphone
  }

  func start(buffer: AudioStreamBuffer) async throws(AudioRecorderError) -> AudioRecording {
    // 上限到達・割り込みで終わった録音の片付けがまだなら、ここで片付けて次の録音を始められるようにする
    if case .recording(let active) = phase, active.pipeline.isEnded { tearDown(active.attempt) }
    guard case .idle = phase else { throw .alreadyRecording }
    lastAttempt += 1
    let attempt = lastAttempt
    phase = .starting(attempt: attempt)

    do throws(AudioRecorderError) {
      try await microphone.ensureAccess()
    } catch {
      if isStarting(attempt) { phase = .idle }
      throw error
    }
    // 許可を待つ間に stop() が呼ばれていたら始めない
    guard isStarting(attempt) else { throw .cancelled }

    do throws(AudioRecorderError) {
      let (active, recording) = try makeRecording(buffer: buffer, attempt: attempt)
      phase = .recording(active)
      // 始めた直後に止まっていたら（構成変更など）、ここで片付ける
      if active.pipeline.isEnded { tearDown(attempt) }
      return recording
    } catch {
      phase = .idle
      throw error
    }
  }

  func stop() {
    switch phase {
    case .idle:
      return
    case .starting:
      phase = .idle
    case .recording(let active):
      tearDown(active.attempt)
    }
  }

  private func isStarting(_ attempt: UInt64) -> Bool {
    guard case .starting(let current) = phase else { return false }
    return current == attempt
  }

  private func makeRecording(
    buffer: AudioStreamBuffer, attempt: UInt64
  ) throws(AudioRecorderError) -> (ActiveRecording, AudioRecording) {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw .inputDeviceUnavailable }
    guard
      let resampler = MonoResampler(
        inputSampleRate: format.sampleRate,
        outputSampleRate: Double(AudioRecordingPipeline.defaultSampleRate))
    else { throw .startFailed }

    let (pipeline, recording) = AudioRecordingPipeline.make(buffer: buffer) { [weak self] _ in
      // 上限到達・割り込み・受け手の破棄で止まったら、エンジンを止めて通知の購読をやめる
      Task { await self?.tearDown(attempt) }
    }
    // 開始の直後に起きた変化を取りこぼさないよう、エンジンを始める前に購読する
    let configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [pipeline] _ in
      pipeline.end(.interrupted(Self.configurationChangeInterruption))
    }
    let sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
    ) { [pipeline] _ in
      pipeline.end(.interrupted(Self.sleepInterruption))
    }
    let active = ActiveRecording(
      attempt: attempt, engine: engine, resampler: resampler, pipeline: pipeline,
      configurationObserver: configurationObserver, sleepObserver: sleepObserver)

    input.installTap(
      onBus: 0, bufferSize: Self.tapBufferSize, format: format,
      block: Self.tapBlock(resampler: resampler, pipeline: pipeline))
    engine.prepare()
    do {
      try engine.start()
    } catch {
      Self.release(active)
      throw .startFailed
    }
    return (active, recording)
  }

  private func tearDown(_ attempt: UInt64) {
    guard case .recording(let active) = phase, active.attempt == attempt else { return }
    phase = .idle
    // 先にタップを外してエンジンを止め、届いた音声をすべて受け取ってから終える
    Self.release(active)
    // 通知から止まった場合はすでに終わっている（残りは受け入れない）。それ以外は変換器に残った音声も流して終える
    active.pipeline.append(active.resampler.flush())
    active.pipeline.end(.finished)
  }

  /// 通知の購読をやめ、タップを外してエンジンを止める
  private static func release(_ active: ActiveRecording) {
    NotificationCenter.default.removeObserver(active.configurationObserver)
    NSWorkspace.shared.notificationCenter.removeObserver(active.sleepObserver)
    active.engine.inputNode.removeTap(onBus: 0)
    active.engine.stop()
  }

  /// エンジンの構成変更を表す値。エンジンは止まっており、録音に使っていた入力機器では続けられない。
  /// UtterCore に macOS の値（#128 の `.audioRouteChanged(.inputDeviceChanged)`）が入るまでは、
  /// 録音を止めて処理する既存の値で表す
  static let configurationChangeInterruption = RecordingInterruption.audioRouteChanged(
    .inputDeviceLost)

  /// スリープを表す値。スリープで OS が録音を止めるため、オーディオ割り込みの開始で表す。
  /// UtterCore に macOS の値（#128 の `.systemWillSleep`）が入ったら置き換える
  static let sleepInterruption = RecordingInterruption.audioInterruptionBegan

  /// 録音のコールバック。オーディオのスレッドで呼ばれるため、アクターに隔離しない
  private nonisolated static func tapBlock(
    resampler: MonoResampler, pipeline: AudioRecordingPipeline
  ) -> AVAudioNodeTapBlock {
    { @Sendable buffer, _ in
      guard !pipeline.isEnded else { return }
      let channels = channelSamples(of: buffer)
      guard !channels.isEmpty else { return }
      pipeline.append(resampler.resample(AudioDownmix.mono(channels)))
    }
  }

  /// バッファのサンプルをチャンネルごとに取り出す。Float32 以外の形式なら空
  private nonisolated static func channelSamples(of buffer: AVAudioPCMBuffer) -> [[Float]] {
    guard let data = buffer.floatChannelData else { return [] }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard buffer.format.isInterleaved else {
      return (0..<channelCount).map {
        Array(UnsafeBufferPointer(start: data[$0], count: frameCount))
      }
    }
    let interleaved = UnsafeBufferPointer(start: data[0], count: frameCount * channelCount)
    return (0..<channelCount).map { channel in
      stride(from: channel, to: interleaved.count, by: channelCount).map { interleaved[$0] }
    }
  }
}
