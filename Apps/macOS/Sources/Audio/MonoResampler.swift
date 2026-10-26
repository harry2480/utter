import AVFoundation
import Synchronization

/// モノラルのサンプルを、音声認識に渡すサンプリング周波数へ変換する（4章）。
///
/// 入力機器のサンプリング周波数（44.1kHz・48kHz など）は機器によって違うため、`AVAudioConverter` で変換する。
/// 変換器は前後のサンプルを使うため、1回の録音の間は同じ変換器に続けて渡す。録音のコールバックから呼ぶため、
/// 変換器はロックで守る。周波数が同じなら変換しない。
final class MonoResampler: Sendable {
  private let converter: Mutex<Converter?>

  private struct Converter {
    let converter: AVAudioConverter
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
  }

  /// 変換できない周波数なら `nil`
  init?(inputSampleRate: Double, outputSampleRate: Double) {
    guard inputSampleRate > 0, outputSampleRate > 0 else { return nil }
    guard inputSampleRate != outputSampleRate else {
      converter = Mutex(nil)
      return
    }
    guard
      let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1,
        interleaved: false),
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1,
        interleaved: false),
      let avConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else { return nil }
    converter = Mutex(
      Converter(converter: avConverter, inputFormat: inputFormat, outputFormat: outputFormat))
  }

  /// 変換したサンプル。変換に失敗したら空（音声は含めずに捨てる）
  func resample(_ samples: [Float]) -> [Float] {
    guard !samples.isEmpty else { return [] }
    return converter.withLock { state -> [Float] in
      guard let state else { return samples }
      guard
        let input = AVAudioPCMBuffer(
          pcmFormat: state.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
        let inputData = input.floatChannelData
      else { return [] }
      input.frameLength = AVAudioFrameCount(samples.count)
      samples.withUnsafeBufferPointer { source in
        guard let base = source.baseAddress else { return }
        inputData[0].update(from: base, count: samples.count)
      }
      return Self.convert(
        InputOnce(input, then: .noDataNow), inputFrameCount: samples.count, with: state)
    }
  }

  /// 録音の終わりに、変換器の中に残ったサンプルを取り出す。以降は使わない
  func flush() -> [Float] {
    converter.withLock { state -> [Float] in
      guard let state else { return [] }
      return Self.convert(InputOnce(nil, then: .endOfStream), inputFrameCount: 0, with: state)
    }
  }

  private static func convert(
    _ supplied: InputOnce, inputFrameCount: Int, with state: Converter
  ) -> [Float] {
    let ratio = state.outputFormat.sampleRate / state.inputFormat.sampleRate
    // 変換器が内部に持つ前後のサンプルの分だけ多めに確保し、満杯になったら続けて取り出す
    let capacity = AVAudioFrameCount((Double(inputFrameCount) * ratio).rounded(.up)) + 256
    var converted: [Float] = []
    while true {
      guard
        let output = AVAudioPCMBuffer(pcmFormat: state.outputFormat, frameCapacity: capacity)
      else { return converted }
      var error: NSError?
      let status = state.converter.convert(to: output, error: &error) { _, inputStatus in
        supplied.next(inputStatus)
      }
      guard status != .error, let outputData = output.floatChannelData else { return converted }
      converted.append(
        contentsOf: UnsafeBufferPointer(start: outputData[0], count: Int(output.frameLength)))
      // .haveData は出力が満杯で、まだ取り出せる音声がある
      guard status == .haveData, output.frameLength > 0 else { return converted }
    }
  }
}

/// 変換器に入力を1回だけ渡す。2回目以降は `afterwards` で答える。録音中は「今はない」（`.noDataNow`）と答え、
/// 変換器の状態（前後のサンプル）を次の呼び出しに残す。録音の終わりは `.endOfStream` で残りを出させる。
/// 変換器の入力ブロックは SDK によって `@Sendable` なので、渡す前の入力は `Mutex` に持つ
private final class InputOnce: Sendable {
  private let buffer: Mutex<AVAudioPCMBuffer?>
  private let afterwards: AVAudioConverterInputStatus

  init(_ buffer: sending AVAudioPCMBuffer?, then afterwards: AVAudioConverterInputStatus) {
    self.buffer = Mutex(buffer)
    self.afterwards = afterwards
  }

  func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    guard let buffer = self.buffer.withLock({ $0.take() }) else {
      status.pointee = afterwards
      return nil
    }
    status.pointee = .haveData
    return buffer
  }
}
