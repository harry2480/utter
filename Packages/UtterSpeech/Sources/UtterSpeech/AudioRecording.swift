import Synchronization
import UtterCore

/// 録音が終わった理由（REC-04, REC-05）。
public enum AudioRecordingEndReason: Hashable, Sendable {
  /// 呼び出し側が録音を終えた
  case finished
  /// 音声バッファ（最大録音時間）の上限に達したため、自動で録音を止めた。HUD で通知する
  case limitReached
  /// 音声の受け手がストリームを破棄した
  case cancelled
  /// OS の通知（入力機器の変化・スリープなど）で録音が止まった。
  /// 値は `SessionStateMachine.handleInterruption(_:capturedAudioDuration:policy:)` へそのまま渡す
  case interrupted(RecordingInterruption)
}

/// 録音の終わり。音声は含めない。
public struct AudioRecordingEnd: Hashable, Sendable {
  public let reason: AudioRecordingEndReason
  /// 音声認識へ流した音声の長さ。割り込みの対応（`RecordingInterruptionPolicy`）の判定に使う
  public let capturedDuration: Duration

  public init(reason: AudioRecordingEndReason, capturedDuration: Duration) {
    self.reason = reason
    self.capturedDuration = capturedDuration
  }
}

/// 録音中の音声と、録音の終わりを受け取る口（REC-04, REC-05）。
public struct AudioRecording: Sendable {
  /// 音声認識へ渡す音声。録音が終わると、それまでの音声をすべて流してから終わる
  public let chunks: AsyncStream<AudioChunk>
  /// 録音の終わり。どの理由で終わっても1回だけ流して終わる
  public let ends: AsyncStream<AudioRecordingEnd>

  public init(chunks: AsyncStream<AudioChunk>, ends: AsyncStream<AudioRecordingEnd>) {
    self.chunks = chunks
    self.ends = ends
  }
}

/// 録音のコールバックから届くモノラルのサンプルを、一定の長さのチャンクに区切って上限つきで流す（REC-04, REC-05）。
///
/// OS の録音 API に依存しない部分で、本番の録音アダプターと `StubAudioRecorder` が使う。
/// `make(buffer:sampleRate:chunkDuration:onEnd:)` で、録音側（このクラス）と受け手に渡す `AudioRecording` を組で作る。
/// このクラスはストリームを持たないため、受け手がストリームを手放すと終了を検知できる。
/// - `append(_:)` はどのスレッドから呼んでもよく、待たずに戻る（録音のコールバックを止めない）
/// - 上限に達したら、収まる分までを流して `.limitReached` で終える。受け手がストリームを破棄したら `.cancelled` で終える
/// - `end(_:)` で終えると、区切りに満たない残りも流してから終える。上限内の音声は黙って捨てない
/// - 終わりは理由によらず1回だけ `ends` に流し、`onEnd` を呼ぶ。録音アダプターは `onEnd` で録音を止める。
///   終わった後に届いたサンプルは受け入れない
public final class AudioRecordingPipeline: Sendable {
  private let stream: BoundedAudioStream
  private let sampleRate: Int
  private let state: Mutex<State>
  private let endContinuation: AsyncStream<AudioRecordingEnd>.Continuation
  private let onEnd: @Sendable (AudioRecordingEnd) -> Void

  private struct State {
    var chunker: AudioChunker
    var isEnded = false
  }

  /// 録音側と、受け手に渡す音声・録音の終わりを作る。
  /// - Parameters:
  ///   - buffer: 音声バッファの上限（REC-05。既定は5分）
  ///   - sampleRate: `append(_:)` に渡すサンプルのサンプリング周波数（Hz）。既定は 16kHz
  ///   - chunkDuration: 音声認識へ流す1チャンクの長さ
  ///   - onEnd: 録音が終わったときに1回だけ呼ぶ。呼ぶスレッドは決まっていない
  public static func make(
    buffer: AudioStreamBuffer = AudioStreamBuffer(),
    sampleRate: Int = AudioRecordingPipeline.defaultSampleRate,
    chunkDuration: Duration = .milliseconds(100),
    onEnd: @escaping @Sendable (AudioRecordingEnd) -> Void = { _ in }
  ) -> (pipeline: AudioRecordingPipeline, recording: AudioRecording) {
    let (stream, chunks) = BoundedAudioStream.make(buffer: buffer)
    let (ends, endContinuation) = AsyncStream.makeStream(of: AudioRecordingEnd.self)
    let pipeline = AudioRecordingPipeline(
      stream: stream, sampleRate: sampleRate, chunkDuration: chunkDuration,
      endContinuation: endContinuation, onEnd: onEnd)
    return (pipeline, AudioRecording(chunks: chunks, ends: ends))
  }

  private init(
    stream: BoundedAudioStream, sampleRate: Int, chunkDuration: Duration,
    endContinuation: AsyncStream<AudioRecordingEnd>.Continuation,
    onEnd: @escaping @Sendable (AudioRecordingEnd) -> Void
  ) {
    self.stream = stream
    self.sampleRate = sampleRate
    self.endContinuation = endContinuation
    self.onEnd = onEnd
    state = Mutex(
      State(chunker: AudioChunker(sampleRate: sampleRate, chunkDuration: chunkDuration)))
  }

  /// 音声認識に渡すサンプリング周波数の既定値（Hz）。`AudioStreamBuffer` の上限の換算と同じ
  public static let defaultSampleRate = 16_000

  /// 録音が終わっていれば `true`
  public var isEnded: Bool {
    state.withLock { $0.isEnded }
  }

  /// 音声認識へ流した音声の長さ
  public var capturedDuration: Duration {
    // byteCount は PCM16 換算（1サンプル = 2バイト）
    .seconds(Double(stream.byteCount / 2) / Double(max(1, sampleRate)))
  }

  /// モノラルのサンプルを足す。録音が終わっていれば何もしない。
  public func append(_ samples: [Float]) {
    let reason = state.withLock { state -> AudioRecordingEndReason? in
      guard !state.isEnded else { return nil }
      for chunk in state.chunker.append(samples) {
        if let reason = yield(chunk) {
          state.isEnded = true
          return reason
        }
      }
      return nil
    }
    if let reason { notifyEnd(reason) }
  }

  /// 録音を終える。区切りに満たない残りも流す。すでに終わっていれば何もしない。
  /// - Returns: この呼び出しで終えたら `true`
  @discardableResult
  public func end(_ reason: AudioRecordingEndReason) -> Bool {
    let ended = state.withLock { state -> AudioRecordingEndReason? in
      guard !state.isEnded else { return nil }
      state.isEnded = true
      // 残りを流した結果で上限に達しても、終わった理由は呼び出し側の理由のままにする
      if let rest = state.chunker.flush() { _ = yield(rest) }
      return reason
    }
    guard let ended else { return false }
    notifyEnd(ended)
    return true
  }

  /// チャンクを流す。録音を終えるべきなら、その理由を返す
  private func yield(_ chunk: AudioChunk) -> AudioRecordingEndReason? {
    switch stream.yield(chunk) {
    case .accepted:
      return nil
    case .limitReached:
      return .limitReached
    case .stopped(.cancelled):
      return .cancelled
    case .stopped(.limitReached):
      return .limitReached
    case .stopped(.finished):
      return .finished
    }
  }

  /// ロックの外で呼ぶ（`onEnd` から `append(_:)` や `end(_:)` が呼ばれても止まらないように）
  private func notifyEnd(_ reason: AudioRecordingEndReason) {
    // 上限到達と受け手の破棄ではストリームはすでに終わっている。それ以外はここで終える
    stream.finish()
    let end = AudioRecordingEnd(reason: reason, capturedDuration: capturedDuration)
    endContinuation.yield(end)
    endContinuation.finish()
    onEnd(end)
  }
}
