import Synchronization

/// 上限つきで音声チャンクを STT へ流すストリーム（REC-05）。
///
/// `make(buffer:)` で録音側（このクラス）と STT が読む `AsyncStream` を組で作る。
/// - `yield(_:)` は待たずに戻る。録音のコールバックを止めないため、消費側が遅い間のチャンクはストリーム内に溜める。
///   溜まる量は PCM16 換算で録音全体の上限（`AudioStreamBuffer.maxBytes`）まで。サンプルは `Float` で持つため、
///   実メモリはその約2倍になる
/// - 上限に達したら、収まる分までを流してストリームを正常に終える。それまでの音声は消費側がすべて読める
/// - 録音側は戻り値か `stopReason` で上限到達を区別し、HUD に通知する
/// - 受け手が読むのをやめた（タスクのキャンセル、またはストリームを破棄した）ら `.cancelled` で止まる。
///   このクラスはストリームを持たないため、受け手が参照を手放すと終了を検知できる
public final class BoundedAudioStream: Sendable {
  private let continuation: AsyncStream<AudioChunk>.Continuation
  private let capture: Mutex<AudioCapture>

  /// 録音側と、STT に渡す音声のストリームを作る
  /// - Parameters:
  ///   - buffer: 音声バッファの上限
  ///   - onCancelled: 受け手が読むのをやめたときに1回だけ呼ぶ（次の `yield(_:)` を待たずに録音を止めるため）。
  ///     呼ぶスレッドは決まっていない。このクラスのロックの外で呼ぶ
  public static func make(
    buffer: AudioStreamBuffer = AudioStreamBuffer(),
    onCancelled: @escaping @Sendable () -> Void = {}
  ) -> (stream: BoundedAudioStream, chunks: AsyncStream<AudioChunk>) {
    // 上限内の音声を落とさないよう、無制限のバッファにする（量は AudioCapture が上限で抑える）
    let (chunks, continuation) = AsyncStream.makeStream(
      of: AudioChunk.self, bufferingPolicy: .unbounded)
    return (
      BoundedAudioStream(buffer: buffer, continuation: continuation, onCancelled: onCancelled),
      chunks
    )
  }

  private init(
    buffer: AudioStreamBuffer, continuation: AsyncStream<AudioChunk>.Continuation,
    onCancelled: @escaping @Sendable () -> Void
  ) {
    self.continuation = continuation
    self.capture = Mutex(AudioCapture(buffer: buffer))
    continuation.onTermination = { [weak self] termination in
      guard case .cancelled = termination else { return }
      self?.capture.withLock { _ = $0.stop(.cancelled) }
      onCancelled()
    }
  }

  /// 録音が止まっていれば、その理由
  public var stopReason: AudioCaptureStopReason? {
    capture.withLock { $0.stopReason }
  }

  /// 受け入れた音声のバイト数（PCM16 換算）
  public var byteCount: Int {
    capture.withLock { $0.byteCount }
  }

  /// チャンクを流す。上限に達したら、収まる分を流してからストリームを終える。
  @discardableResult
  public func yield(_ chunk: AudioChunk) -> AudioAppendResult {
    // 複数のスレッドから呼ばれても順序が入れ替わらないよう、受け入れと yield を同じロック内で行う
    let result = capture.withLock { capture in
      var next = capture
      let (result, kept) = next.append(chunk)
      // 受け手がすでに読むのをやめていれば、受け入れたことにせず止める（届かない音声を受け入れ済みと報告しない）
      if let kept, case .terminated = continuation.yield(kept) {
        capture.stop(.cancelled)
        return AudioAppendResult.stopped(.cancelled)
      }
      capture = next
      return result
    }
    // finish() は onTermination を同期的に呼び得るため、ロックの外で呼ぶ
    if case .limitReached = result {
      continuation.finish()
    }
    return result
  }

  /// 録音を終える。それまでに流したチャンクは、消費側がすべて読める。
  public func finish() {
    capture.withLock { _ = $0.stop(.finished) }
    continuation.finish()
  }
}
