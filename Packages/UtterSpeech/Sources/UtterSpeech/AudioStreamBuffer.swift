/// 音声ストリームのバッファ設定と上限管理（REC-05）。
///
/// 上限はバイト数で指定し、到達時は caller に通知する。
/// AsyncStream の上限制御は caller の責務であり、ここで仕組みを提供する。
public struct AudioStreamBuffer: Sendable {
  /// バッファの最大サイズ（バイト数）
  public let maxBytes: Int

  /// 既定: 5分の PCM16kHz モノラル（約5.76MB）
  public static let defaultMaxBytes = 16_000 * 2 * 60 * 5

  /// バッファの上限を指定して初期化
  /// - Parameters:
  ///   - maxBytes: 最大サイズ（バイト数）。0以下は拒否
  public init(maxBytes: Int = Self.defaultMaxBytes) {
    self.maxBytes = max(1, maxBytes)
  }

  /// 現在のデータサイズから、上限に達するまでのバイト数を計算
  public func remainingBytes(currentSize: Int) -> Int {
    max(0, maxBytes - currentSize)
  }

  /// 上限に達したか判定
  public func isLimitReached(currentSize: Int) -> Bool {
    currentSize >= maxBytes
  }
}
