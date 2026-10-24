import AVFoundation
import Speech
import Synchronization

/// 音声時刻 0 に対応する壁時計の時刻。結果の遅延 = 受信時刻 − (この時刻 + 結果の音声終了時刻)。
final class AudioOrigin: Sendable {
  private let instant = Mutex<ContinuousClock.Instant?>(nil)

  var value: ContinuousClock.Instant? { instant.withLock { $0 } }

  /// 最初の1回だけ設定する
  func setIfUnset(_ value: ContinuousClock.Instant) {
    instant.withLock { if $0 == nil { $0 = value } }
  }
}

/// 入力音声を SpeechAnalyzer の形式へ変換する。形式が同じならそのまま返す。
///
/// サンプルレート変換の内部状態を保つため、入力が尽きたとき以外は `.noDataNow` を返す。
final class BufferConverter {
  private let converter: AVAudioConverter?
  private let outputFormat: AVAudioFormat

  init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
    self.outputFormat = outputFormat
    if inputFormat == outputFormat {
      converter = nil
    } else {
      guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
        throw ProbeError("音声形式を変換できません: \(inputFormat) → \(outputFormat)")
      }
      self.converter = converter
    }
  }

  func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    guard let converter else { return buffer }
    let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
    return try run(converter, capacity: capacity, input: buffer)
  }

  /// 変換器に残ったフレームを取り出す（入力の終わりで1回呼ぶ）
  func flush() throws -> AVAudioPCMBuffer? {
    guard let converter else { return nil }
    return try run(converter, capacity: 4096, input: nil)
  }

  private func run(
    _ converter: AVAudioConverter, capacity: AVAudioFrameCount, input: AVAudioPCMBuffer?
  )
    throws -> AVAudioPCMBuffer
  {
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      throw ProbeError("変換先のバッファを確保できません")
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
    if status == .error {
      throw ProbeError("音声の変換に失敗しました: \(error?.localizedDescription ?? "不明")")
    }
    return output
  }
}

/// 音声ファイルを 100ms ごとに渡す。`pace == .realtime` なら音声の長さどおりに待つ。
/// 戻り値は渡した音声の長さ（秒）。キャンセルされたらそこまでの長さを返す。
func feedFile(
  url: URL, pace: Pace, format: AVAudioFormat, origin: AudioOrigin,
  continuation: AsyncStream<AnalyzerInput>.Continuation
) async throws -> Double {
  let file = try AVAudioFile(forReading: url)
  let inputFormat = file.processingFormat
  let converter = try BufferConverter(from: inputFormat, to: format)
  let chunkFrames = AVAudioFrameCount(max(1, (inputFormat.sampleRate * 0.1).rounded()))
  let start = ContinuousClock.now
  origin.setIfUnset(start)
  var fedFrames: AVAudioFramePosition = 0

  while file.framePosition < file.length {
    if Task.isCancelled { break }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames) else {
      throw ProbeError("読み込み用のバッファを確保できません")
    }
    try file.read(into: buffer, frameCount: chunkFrames)
    guard buffer.frameLength > 0 else { break }
    let chunkEndFrames = fedFrames + AVAudioFramePosition(buffer.frameLength)
    if pace == .realtime {
      // マイクと同じく、チャンクの終わりの時刻になってから渡す
      let chunkEnd = start + .seconds(Double(chunkEndFrames) / inputFormat.sampleRate)
      do {
        try await Task.sleep(until: chunkEnd, clock: .continuous)
      } catch {
        break
      }
    }
    let converted = try converter.convert(buffer)
    if converted.frameLength > 0 {
      continuation.yield(AnalyzerInput(buffer: converted))
    }
    // 渡したチャンクだけを音声の長さに数える（キャンセルで渡さなかった分は含めない）
    fedFrames = chunkEndFrames
  }
  if let rest = try converter.flush(), rest.frameLength > 0, !Task.isCancelled {
    continuation.yield(AnalyzerInput(buffer: rest))
  }
  return Double(fedFrames) / inputFormat.sampleRate
}

/// 既定の入力デバイス（内蔵マイク等）から `seconds` 秒だけ録音して渡す。音声は保存しない。
/// 戻り値は渡した音声の長さ（秒）。
func feedMicrophone(
  seconds: Double, format: AVAudioFormat, origin: AudioOrigin,
  continuation: AsyncStream<AnalyzerInput>.Continuation
) async throws -> Double {
  let engine = AVAudioEngine()
  let input = engine.inputNode
  let inputFormat = input.outputFormat(forBus: 0)
  guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
    throw ProbeError("入力デバイスがありません（マイクの権限と入力デバイスを確認してください）")
  }
  // 変換器はタップのスレッドで使い、flush はタップを外してエンジンを止めた後にだけ呼ぶ
  // （AVAudioConverter はスレッド安全でないため、同時に触らない順序で使う）
  let converter = try BufferConverter(from: inputFormat, to: format)
  let capturedFrames = Mutex<AVAudioFramePosition>(0)
  let conversionFailed = Mutex(false)

  input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
    // 最初のバッファの先頭を音声時刻 0 とみなす（入力デバイスの遅延は含まない）
    let duration = Double(buffer.frameLength) / inputFormat.sampleRate
    origin.setIfUnset(ContinuousClock.now - .seconds(duration))
    capturedFrames.withLock { $0 += AVAudioFramePosition(buffer.frameLength) }
    do {
      let converted = try converter.convert(buffer)
      if converted.frameLength > 0 {
        continuation.yield(AnalyzerInput(buffer: converted))
      }
    } catch {
      conversionFailed.withLock { $0 = true }
    }
  }
  engine.prepare()
  try engine.start()
  printError("録音中（\(fixed(seconds, digits: 1)) 秒）…")
  do {
    try await Task.sleep(for: .seconds(seconds))
  } catch {
    // キャンセル（--cancel-after）。ここまでの音声で終える
  }
  // 先にタップを外してからエンジンを止め、タップのスレッドが変換器を触らなくなってから flush する
  input.removeTap(onBus: 0)
  engine.stop()
  // サンプルレート変換器に残った末尾のフレームも渡す（発話の終わりを欠かさない）
  if let rest = try converter.flush(), rest.frameLength > 0 {
    continuation.yield(AnalyzerInput(buffer: rest))
  }
  if conversionFailed.withLock({ $0 }) {
    throw ProbeError("マイク入力の変換に失敗しました")
  }
  return Double(capturedFrames.withLock { $0 }) / inputFormat.sampleRate
}
