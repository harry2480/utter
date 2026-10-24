/// 録音のコールバックから届くサンプルを、一定の長さのチャンクに区切る（4章, REC-05）。
///
/// 入力機器やコールバックによって届くサンプル数は揃わないため、`chunkDuration` ごとにまとめて
/// 音声認識へ流す。区切りに満たない残りは次のサンプルと合わせ、録音の終わりに `flush()` で流す。
/// サンプルは -1.0〜1.0 に丸め、NaN は無音にする（`AudioChunk` の値の範囲を守る）。
public struct AudioChunker: Sendable {
  /// 区切ったチャンクのサンプリング周波数（Hz）
  public let sampleRate: Int
  /// 1チャンクのサンプル数（1以上）
  public let samplesPerChunk: Int
  private var pending: [Float] = []

  /// - Parameters:
  ///   - sampleRate: サンプルのサンプリング周波数（Hz）
  ///   - chunkDuration: 1チャンクの長さ。1サンプルに満たなければ1サンプルずつ区切る
  public init(sampleRate: Int, chunkDuration: Duration = .milliseconds(100)) {
    self.sampleRate = sampleRate
    samplesPerChunk = AudioSampleCount.samples(in: chunkDuration, sampleRate: sampleRate)
  }

  /// 区切りに満たず、まだ流していないサンプル数
  public var pendingSampleCount: Int { pending.count }

  /// サンプルを足し、区切りに達した分のチャンクを返す。
  public mutating func append(_ samples: [Float]) -> [AudioChunk] {
    pending.append(contentsOf: samples.lazy.map(Self.sanitize))
    guard pending.count >= samplesPerChunk else { return [] }
    let fullCount = pending.count - pending.count % samplesPerChunk
    let chunks = stride(from: 0, to: fullCount, by: samplesPerChunk).map { start in
      AudioChunk(
        samples: Array(pending[start..<start + samplesPerChunk]), sampleRate: sampleRate)
    }
    pending.removeFirst(fullCount)
    return chunks
  }

  /// 区切りに満たない残りを1つのチャンクにして返す。残りがなければ `nil`。
  public mutating func flush() -> AudioChunk? {
    guard !pending.isEmpty else { return nil }
    defer { pending = [] }
    return AudioChunk(samples: pending, sampleRate: sampleRate)
  }

  static func sanitize(_ sample: Float) -> Float {
    guard !sample.isNaN else { return 0 }
    return min(max(sample, -1), 1)
  }
}

/// 複数チャンネルの音声をモノラルにまとめる（4章）。
public enum AudioDownmix {
  /// チャンネルごとのサンプルを平均してモノラルにする。
  ///
  /// どのチャンネルにマイクの音が入っているかは入力機器によって違うため、特定のチャンネルを選ばずに平均する
  /// （音の大きさは下がり得るが、どのチャンネルの音も失わない）。長さが違うときは短いチャンネルに合わせる。
  public static func mono(_ channels: [[Float]]) -> [Float] {
    guard let first = channels.first else { return [] }
    guard channels.count > 1 else { return first }
    let frameCount = channels.map(\.count).min() ?? 0
    let scale = 1 / Float(channels.count)
    return (0..<frameCount).map { frame in
      channels.reduce(Float(0)) { $0 + $1[frame] } * scale
    }
  }
}
