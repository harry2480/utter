/// 音声ストリームのバッファ設定と上限管理（REC-05）。
///
/// 上限はバイト数で指定し、到達時は caller に通知する。
/// AsyncStream の上限制御は caller の責務であり、ここで仕組みを提供する。
public struct AudioStreamBuffer: Sendable {
  /// バッファの最大サイズ（バイト数）
  public let maxBytes: Int

  /// 既定: 5分の PCM16kHz モノラル（16kHz × 2 bytes × 60s × 5 = 9.6MB）
  public static let defaultMaxBytes = 16_000 * 2 * 60 * 5

  /// バッファの上限を指定して初期化
  /// - Parameters:
  ///   - maxBytes: 最大サイズ（バイト数）。0以下は1バイトに調整
  public init(maxBytes: Int = Self.defaultMaxBytes) {
    self.maxBytes = max(1, maxBytes)
  }

  /// AudioChunk のバイト数を計算
  /// - Parameters:
  ///   - chunk: 音声チャンク
  /// - Returns: Float 配列を PCM16 バイト数に変換（1 サンプル = 2 バイト）
  public func sizeInBytes(of chunk: AudioChunk) -> Int {
    chunk.samples.count * 2
  }

  /// チャンク受け入れ可否判定（バックプレッシャー）
  /// - Parameters:
  ///   - chunk: 受け入れを検討する音声チャンク
  ///   - currentSize: 現在のバッファサイズ
  /// - Returns: 受け入れ可否
  public func canAccept(_ chunk: AudioChunk, currentSize: Int) -> Bool {
    let chunkSize = sizeInBytes(of: chunk)
    return currentSize + chunkSize <= maxBytes
  }

  /// 現在のデータサイズから、上限に達するまでのバイト数を計算
  /// - Parameters:
  ///   - currentSize: 現在のサイズ（バイト数）。0以上を想定
  /// - Returns: 残り容量。負の値は0に調整
  public func remainingBytes(currentSize: Int) -> Int {
    guard currentSize >= 0 else { return maxBytes }
    return max(0, maxBytes - currentSize)
  }

  /// 上限に達したか判定
  public func isLimitReached(currentSize: Int) -> Bool {
    currentSize >= maxBytes
  }
}
