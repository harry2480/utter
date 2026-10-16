/// 音声ストリームのバッファ設定と上限管理（REC-05）。
///
/// 上限はバイト数で指定し、到達時は caller に通知する。
/// **バックプレッシャー実装：** AsyncStream の generator で `canAccept()` を呼び出し、
/// 拒否時は `yield` を中止し、ユーザーに通知・recording を停止する責務は caller にある。
///
/// **PCM16 前提：** このバッファは PCM16kHz（16-bit signed, 1 sample = 2 bytes）を想定する。
/// 異なるフォーマットの場合は `sizeInBytes()` 実装側で変換する。
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

  /// AudioChunk のバイト数を計算（PCM16 前提）
  /// - Parameters:
  ///   - chunk: 音声チャンク（samples は PCM16 を想定、sampleRate: 16_000）
  /// - Returns: PCM16 バイト数（1 サンプル = 2 バイト）。負の値は0に調整
  public func sizeInBytes(of chunk: AudioChunk) -> Int {
    guard chunk.samples.count >= 0 else { return 0 }
    let count = chunk.samples.count
    guard count <= Int.max / 2 else { return Int.max }
    return count * 2
  }

  /// チャンク受け入れ可否判定（バックプレッシャー）
  ///
  /// **使用例（generator 内）:**
  /// ```swift
  /// if buffer.canAccept(chunk, currentSize: currentSize) {
  ///   await stream.yield(chunk)
  ///   currentSize += buffer.sizeInBytes(of: chunk)
  /// } else {
  ///   // 停止通知、recording 中止、finish() を caller が実装する
  ///   return
  /// }
  /// ```
  /// - Parameters:
  ///   - chunk: 受け入れを検討する音声チャンク（sampleRate: 16_000 想定）
  ///   - currentSize: 現在のバッファサイズ（バイト数）。負の値は 0 として扱う
  /// - Returns: `true` = チャンク受け入れ可、`false` = バッファ満杯またはオーバーフロー検出
  public func canAccept(_ chunk: AudioChunk, currentSize: Int) -> Bool {
    guard currentSize >= 0 else { return canAccept(chunk, currentSize: 0) }
    guard currentSize <= maxBytes else { return false }
    let chunkSize = sizeInBytes(of: chunk)
    guard chunkSize >= 0 else { return false }
    guard currentSize <= maxBytes - chunkSize else { return false }
    return true
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
