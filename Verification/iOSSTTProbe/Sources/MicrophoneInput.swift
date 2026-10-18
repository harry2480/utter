import AVFoundation
import Speech

/// AVAudioEngine の入力を認識器の形式へ変換し、AnalyzerInput として流す。
///
/// タップのクロージャはオーディオスレッドで呼ばれる。MainActor の文脈で作ると
/// MainActor に隔離されたクロージャになり実行時に落ちるため、隔離のない static 関数で作る。
final class MicrophoneInput {
  private let engine = AVAudioEngine()
  private var isTapInstalled = false

  func start(
    analyzerFormat: AVAudioFormat,
    continuation: AsyncStream<AnalyzerInput>.Continuation
  ) throws {
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw ProbeError.microphoneUnavailable
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
      throw ProbeError.audioFormatUnsupported
    }
    input.installTap(
      onBus: 0,
      bufferSize: 4096,
      format: inputFormat,
      block: Self.makeTapBlock(
        converter: converter,
        analyzerFormat: analyzerFormat,
        continuation: continuation
      )
    )
    isTapInstalled = true
    engine.prepare()
    do {
      try engine.start()
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    if isTapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      isTapInstalled = false
    }
    engine.stop()
  }

  private static func makeTapBlock(
    converter: AVAudioConverter,
    analyzerFormat: AVAudioFormat,
    continuation: AsyncStream<AnalyzerInput>.Continuation
  ) -> AVAudioNodeTapBlock {
    { buffer, _ in
      guard let converted = convert(buffer, using: converter, to: analyzerFormat) else { return }
      continuation.yield(AnalyzerInput(buffer: converted))
    }
  }

  private static func convert(
    _ buffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    to format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      return nil
    }
    var consumed = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      if consumed {
        // ストリームの途中なので endOfStream ではなく noDataNow を返す（変換器の状態を保つ）
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0 else { return nil }
    return output
  }
}
