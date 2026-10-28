import Foundation

/// 録音中に出す音量の波形（#201）。
///
/// チャンクごとの音量（0〜1）だけを、新しいものから決まった数だけ持つ。音声のサンプルは持たず、
/// 保存・送信もしない。値型なので、利用側は `@MainActor` などに隔離して保持する。
public struct AudioLevelHistory: Hashable, Sendable {
  /// 持つ音量の数の既定値（100ms のチャンクで約 5 秒分）
  public static let defaultCapacity = 48
  /// 無音とみなす音量（dBFS）。これより小さい音は 0 にする
  static let floorDecibels: Float = -50

  /// 持つ音量の数の上限（1 以上）
  public let capacity: Int
  /// 音量（0〜1）。古い順
  public private(set) var levels: [Float] = []

  public init(capacity: Int = AudioLevelHistory.defaultCapacity) {
    self.capacity = max(1, capacity)
  }

  /// 音量を足す。上限を超えたら古いものから捨てる。範囲外は 0〜1 に収め、非有限の値は 0 にする
  public mutating func append(_ level: Float) {
    levels.append(level.isFinite ? min(max(level, 0), 1) : 0)
    if levels.count > capacity {
      levels.removeFirst(levels.count - capacity)
    }
  }

  /// チャンクの音量。サンプル（-1.0〜1.0）の二乗平均平方根を dBFS にし、-50〜0 dB を 0〜1 に写す。
  /// 空・無音は 0。非有限のサンプルは無音として数える
  public static func level(of samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for sample in samples where sample.isFinite {
      sum += sample * sample
    }
    let rms = (sum / Float(samples.count)).squareRoot()
    guard rms > 0 else { return 0 }
    let decibels = 20 * log10(rms)
    let normalized = (decibels - floorDecibels) / -floorDecibels
    return normalized.isFinite ? min(max(normalized, 0), 1) : 0
  }
}
