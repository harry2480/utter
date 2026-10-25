import AVFoundation

/// `AudioChunk`（モノラル Float の PCM）を、SpeechAnalyzer が受け付ける形式の `AVAudioPCMBuffer` に変換する（4章）。
///
/// - 最初のチャンクのサンプリング周波数を入力の形式とし、途中で周波数が変わったら `unsupportedAudioFormat` で失敗する
/// - サンプリング周波数の変換は内部状態（フィルターの履歴）を持つため、1つの録音には1つの変換器を使い、
///   入力の終わりで `flush()` を1回呼んで残りのフレームを取り出す
/// - `AVAudioConverter` はスレッド安全でないため、このクラスは1つのタスクの中だけで使う（`Sendable` にしない）
final class AudioChunkConverter {
  let outputFormat: AVAudioFormat
  private var inputFormat: AVAudioFormat?
  /// 入力と出力の形式が同じなら `nil`（変換せずに渡す）
  private var converter: AVAudioConverter?

  init(outputFormat: AVAudioFormat) {
    self.outputFormat = outputFormat
  }

  /// チャンクを変換する。出力のフレームがなければ `nil`（空のチャンク、または変換器が次の入力を待っている）。
  func convert(_ chunk: AudioChunk) throws(SpeechRecognitionError) -> AVAudioPCMBuffer? {
    guard !chunk.samples.isEmpty else { return nil }
    let input = try makeInputBuffer(chunk)
    guard let converter else { return input }
    let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
    // 変換器が内部に溜めたフレームも同時に出てくるため、余裕を持たせる
    let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
    return try run(converter, capacity: capacity, input: input)
  }

  /// 変換器に残ったフレームを取り出す。入力の終わりで1回だけ呼ぶ。
  func flush() throws(SpeechRecognitionError) -> AVAudioPCMBuffer? {
    guard let converter else { return nil }
    return try run(converter, capacity: 4096, input: nil)
  }

  private func makeInputBuffer(_ chunk: AudioChunk) throws(SpeechRecognitionError)
    -> AVAudioPCMBuffer
  {
    let format = try inputFormat(for: chunk.sampleRate)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
      let channel = buffer.floatChannelData?[0]
    else { throw .resourceLimited }
    chunk.samples.withUnsafeBufferPointer { samples in
      guard let base = samples.baseAddress else { return }
      channel.update(from: base, count: samples.count)
    }
    buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
    return buffer
  }

  /// 最初のチャンクで入力の形式と変換器を決める。以後は同じ周波数のチャンクだけを受け付ける。
  private func inputFormat(for sampleRate: Int) throws(SpeechRecognitionError) -> AVAudioFormat {
    if let inputFormat {
      guard Int(inputFormat.sampleRate) == sampleRate else { throw .unsupportedAudioFormat }
      return inputFormat
    }
    guard sampleRate > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
        interleaved: false)
    else { throw .unsupportedAudioFormat }
    if format != outputFormat {
      guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
        throw .unsupportedAudioFormat
      }
      self.converter = converter
    }
    inputFormat = format
    return format
  }

  /// `input` を1回だけ渡して変換する。`nil` なら入力の終わりとして残りを取り出す。
  /// 入力が尽きても変換器の内部状態を保つよう、入力の終わり以外では `.noDataNow` を返す（Probe で確認した使い方）。
  private func run(
    _ converter: AVAudioConverter, capacity: AVAudioFrameCount, input: AVAudioPCMBuffer?
  ) throws(SpeechRecognitionError) -> AVAudioPCMBuffer? {
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      throw .resourceLimited
    }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      guard let input else {
        inputStatus.pointee = .endOfStream
        return nil
      }
      if consumed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      inputStatus.pointee = .haveData
      return input
    }
    guard status != .error else { throw .unsupportedAudioFormat }
    return output.frameLength > 0 ? output : nil
  }
}
