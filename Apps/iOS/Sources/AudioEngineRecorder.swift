import AVFoundation
import Synchronization
import UtterSpeech
import UtteriOSKit

/// AVAudioSession と AVAudioEngine による録音（12.4節, iOS-PERF-03）。
///
/// マイクの入力を 16kHz モノラルの `AudioChunk` に変換して渡すだけで、音声をファイル・ログには出さない。
/// オーディオセッションは録音カテゴリ（`.record`）で、録音中だけ有効にする（iOS-PERF-02: 待機中にマイクを使わない）。
/// 経路の変更（ヘッドセットの抜き差しなど）でエンジンが止まったら、新しい入力の形式で作り直して続ける。
/// 録音を止めるかは割り込みの通知（`RecordingSignalObserver`）と `RecordingInterruptionPolicy` が決め、
/// 作り直せなかったときだけ `onFailure` で知らせる。
@MainActor
final class AudioEngineRecorder: UtteriOSKit.AudioRecorder {
  enum RecorderError: Error {
    /// 入力の形式を取得できない（マイクがない・使えない）
    case microphoneUnavailable
    /// 16kHz モノラルへ変換できない
    case unsupportedFormat
  }

  /// `AudioStreamBuffer` の PCM16 16kHz の前提に合わせる
  let sampleRate = 16_000

  private var engine: AVAudioEngine?
  private var configurationObserver: (any NSObjectProtocol)?
  private var onChunk: (@Sendable (AudioChunk) -> Void)?
  private var onFailure: (@Sendable () -> Void)?
  private var isSessionActive = false
  /// 録音を始めたときの入力ポート。経路の変更でこれが消えたら作り直さない
  private var inputPortIDs: Set<String> = []

  func requestPermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  func start(
    onChunk: @escaping @Sendable (AudioChunk) -> Void,
    onFailure: @escaping @Sendable () -> Void
  ) throws {
    stop()
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .default)
    try session.setActive(true)
    isSessionActive = true
    inputPortIDs = Self.currentInputPortIDs()
    do {
      try startEngine(onChunk: onChunk)
    } catch {
      stop()
      throw error
    }
    self.onChunk = onChunk
    self.onFailure = onFailure
  }

  func stop() {
    stopEngine()
    onChunk = nil
    onFailure = nil
    inputPortIDs = []
    if isSessionActive {
      isSessionActive = false
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  /// エンジンは録音のたびに作る（メディアサービスのリセット後に古いエンジンを使わない）
  private func startEngine(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    // 経路の変更の直後は、ハードウェアの形式と食い違うことがある。食い違った形式で installTap すると
    // 例外（Swift では捕まえられない）になるため、そろっていなければ開始しない
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
      input.inputFormat(forBus: 0).sampleRate == inputFormat.sampleRate
    else {
      throw RecorderError.microphoneUnavailable
    }
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
        interleaved: false),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      throw RecorderError.unsupportedFormat
    }
    input.installTap(
      onBus: 0, bufferSize: 4096, format: inputFormat,
      block: Self.makeTapBlock(converter: converter, outputFormat: outputFormat, onChunk: onChunk))
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
    self.engine = engine
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] notification in
      let source = (notification.object as AnyObject?).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        // 取り除く前に積まれていた古いエンジンの通知で、作り直した後のエンジンを止めない
        guard let self, let engine = self.engine, source == ObjectIdentifier(engine) else {
          return
        }
        self.restartAfterConfigurationChange()
      }
    }
  }

  private func stopEngine() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      self.engine = nil
    }
  }

  /// 経路の変更で止まったエンジンを、新しい入力の形式で作り直す。作り直せなければ録音の失敗として知らせる。
  ///
  /// 録音を始めたときの入力（ヘッドセットなど）が消えていたら作り直さない。経路の変更の通知より先にこの通知が届くと、
  /// 内蔵マイクに切り替わって周囲の音を録ってしまうため（RecordingInterruptionPolicy.stopsOnInputDeviceLoss）
  private func restartAfterConfigurationChange() {
    guard engine != nil, let onChunk else { return }
    stopEngine()
    guard inputPortIDs.isSubset(of: Self.currentInputPortIDs()) else {
      onFailure?()
      return
    }
    do {
      try startEngine(onChunk: onChunk)
    } catch {
      onFailure?()
    }
  }

  private static func currentInputPortIDs() -> Set<String> {
    Set(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid))
  }

  /// タップのクロージャは録音のスレッドで呼ばれる。MainActor の文脈で作ると MainActor に隔離されたクロージャになり
  /// 実行時に落ちるため、隔離のない static 関数で作る（Verification/iOSSTTProbe と同じ）
  private nonisolated static func makeTapBlock(
    converter: AVAudioConverter,
    outputFormat: AVAudioFormat,
    onChunk: @escaping @Sendable (AudioChunk) -> Void
  ) -> AVAudioNodeTapBlock {
    let sampleRate = Int(outputFormat.sampleRate)
    return { buffer, _ in
      guard let converted = convert(buffer, using: converter, to: outputFormat),
        let channel = converted.floatChannelData?[0]
      else { return }
      let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
      onChunk(AudioChunk(samples: samples, sampleRate: sampleRate))
    }
  }

  private nonisolated static func convert(
    _ buffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    to format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      return nil
    }
    guard let input = PendingInput(copying: buffer) else { return nil }
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      guard let buffer = input.take() else {
        // ストリームの途中なので endOfStream ではなく noDataNow を返す（変換器の状態を保つ）
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

/// 変換器の入力ブロックは SDK によって `@Sendable` なので、タップのバッファを直接渡せない。
/// サンプルを写した新しいバッファを `Mutex` に持ち、1回だけ取り出す
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

  func take() -> AVAudioPCMBuffer? {
    buffer.withLock { $0.take() }
  }
}
