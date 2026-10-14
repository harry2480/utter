/// 音声認識へ渡す音声の断片（4章）。OS 固有の型を使わず、モノラルの PCM サンプルで表す。
public struct AudioChunk: Hashable, Sendable {
  /// -1.0〜1.0 のモノラル PCM サンプル
  public let samples: [Float]
  /// サンプリング周波数（Hz）
  public let sampleRate: Int

  public init(samples: [Float], sampleRate: Int) {
    self.samples = samples
    self.sampleRate = sampleRate
  }

  /// 音声の長さ（ナノ秒単位で切り捨て）。サンプリング周波数が 0 以下なら `.zero`
  ///
  /// 足し引きしても誤差が積もらないよう、浮動小数点を使わずに整数で求める。
  public var duration: Duration {
    guard sampleRate > 0 else { return .zero }
    let (seconds, remainder) = samples.count.quotientAndRemainder(dividingBy: sampleRate)
    return .seconds(seconds) + .nanoseconds(remainder * 1_000_000_000 / sampleRate)
  }
}

// 音声をログに出さないよう、文字列表現とリフレクションにはサンプル数と周波数だけを出す。
extension AudioChunk: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "AudioChunk(sampleCount: \(samples.count), sampleRate: \(sampleRate))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["sampleCount": samples.count, "sampleRate": sampleRate])
  }
}
