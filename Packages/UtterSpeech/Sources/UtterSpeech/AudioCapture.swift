/// 録音が止まった理由（REC-05）。HUD の通知を出し分けるため、上限到達を区別する。
public enum AudioCaptureStopReason: Hashable, Sendable {
  /// 呼び出し側が録音を終えた
  case finished
  /// バッファの上限に達したため、自動で録音を止めた
  case limitReached
  /// 音声の受け手がストリームを破棄した
  case cancelled
}

/// チャンクを追加した結果（REC-05）。
public enum AudioAppendResult: Hashable, Sendable {
  /// すべてのサンプルを受け入れた
  case accepted
  /// 上限に達したため録音を止めた。このチャンクのうち、上限に収まる先頭 `keptSampleCount` 個を残した
  case limitReached(keptSampleCount: Int)
  /// すでに録音が止まっているため、このチャンクは受け入れていない
  case stopped(AudioCaptureStopReason)
}

/// 録音中に受け入れた音声の量と停止状態を管理する（REC-05）。
///
/// 音声そのものは持たず、受け入れたバイト数だけを数える。上限に達したら、収まる分まで残して停止扱いにし、
/// それ以降のチャンクは受け入れない。上限に収まる音声は黙って捨てない。
public struct AudioCapture: Sendable {
  public let buffer: AudioStreamBuffer
  /// 受け入れた音声のバイト数（PCM16 換算）
  public private(set) var byteCount = 0
  /// 録音が止まっていれば、その理由
  public private(set) var stopReason: AudioCaptureStopReason?

  public init(buffer: AudioStreamBuffer = AudioStreamBuffer()) {
    self.buffer = buffer
  }

  /// チャンクを受け入れる。上限を超える場合は、収まる先頭のサンプルだけを残して停止する。
  /// - Returns: 結果と、処理対象として残すチャンク（受け入れなかった場合と空のチャンクは `nil`）
  public mutating func append(_ chunk: AudioChunk) -> (result: AudioAppendResult, kept: AudioChunk?)
  {
    if let stopReason {
      return (.stopped(stopReason), nil)
    }
    // 空のチャンクは音声を持たないため流さない。バイト数が増えないまま溜まり続けるのを防ぐ
    guard !chunk.samples.isEmpty else {
      return (.accepted, nil)
    }
    if buffer.canAccept(chunk, currentSize: byteCount) {
      byteCount += buffer.sizeInBytes(of: chunk)
      guard buffer.isLimitReached(currentSize: byteCount) else {
        return (.accepted, chunk)
      }
      stopReason = .limitReached
      return (.limitReached(keptSampleCount: chunk.samples.count), chunk)
    }

    let keptSampleCount = buffer.remainingBytes(currentSize: byteCount) / Self.bytesPerSample
    stopReason = .limitReached
    guard keptSampleCount > 0 else {
      return (.limitReached(keptSampleCount: 0), nil)
    }
    let kept = AudioChunk(
      samples: Array(chunk.samples.prefix(keptSampleCount)), sampleRate: chunk.sampleRate)
    byteCount += buffer.sizeInBytes(of: kept)
    return (.limitReached(keptSampleCount: keptSampleCount), kept)
  }

  /// 録音を止める。すでに止まっていれば理由を変えない。
  /// - Returns: この呼び出しで止めたら `true`
  @discardableResult
  public mutating func stop(_ reason: AudioCaptureStopReason) -> Bool {
    guard stopReason == nil else { return false }
    stopReason = reason
    return true
  }

  /// `AudioStreamBuffer.sizeInBytes(of:)` と同じ PCM16 前提
  private static let bytesPerSample = 2
}
