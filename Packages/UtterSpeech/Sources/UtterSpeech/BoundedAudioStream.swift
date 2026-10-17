import Synchronization

/// 上限つきで音声チャンクを STT へ流すストリーム（REC-05）。
///
/// 録音側は `yield(_:)` でチャンクを渡し、STT は `chunks` を読む。
/// - `yield(_:)` は待たずに戻る。録音のコールバックを止めないため、消費側が遅い間のチャンクはストリーム内に溜める。
///   溜まる量は録音全体の上限（`AudioStreamBuffer.maxBytes`）を超えない
/// - 上限に達したら、収まる分までを流してストリームを正常に終える。それまでの音声は消費側がすべて読める
/// - 録音側は戻り値か `stopReason` で上限到達を区別し、HUD に通知する
public final class BoundedAudioStream: Sendable {
  /// STT に渡す音声
  public let chunks: AsyncStream<AudioChunk>
  private let continuation: AsyncStream<AudioChunk>.Continuation
  private let capture: Mutex<AudioCapture>

  public init(buffer: AudioStreamBuffer = AudioStreamBuffer()) {
    // 上限内の音声を落とさないよう、無制限のバッファにする（量は AudioCapture が上限で抑える）
    let (chunks, continuation) = AsyncStream.makeStream(
      of: AudioChunk.self, bufferingPolicy: .unbounded)
    self.chunks = chunks
    self.continuation = continuation
    self.capture = Mutex(AudioCapture(buffer: buffer))
    continuation.onTermination = { [weak self] termination in
      guard case .cancelled = termination else { return }
      self?.capture.withLock { _ = $0.stop(.cancelled) }
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
      let (result, kept) = capture.append(chunk)
      if let kept {
        continuation.yield(kept)
      }
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
