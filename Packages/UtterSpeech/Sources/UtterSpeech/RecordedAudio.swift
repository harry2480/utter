import Foundation
import Synchronization

/// 再処理のために一時保存する録音音声（7章, AC-10）。
///
/// 録音中のチャンクを `append(_:)` で溜め、`encoded()` のバイト列を一時音声の保存先（`TemporaryAudioStore`）へ渡す。
/// STT Worker の異常終了後や次回起動時の復旧では、読み込んだバイト列を `init(decoding:)` で戻し、
/// `stream(chunkDuration:)` で音声認識へ流し直す。
///
/// 保存形式はモノラルの PCM16（REC-05 の音声バッファ上限と同じ換算）で、先頭に形式の識別子・版・
/// サンプリング周波数を置く。-1.0〜1.0 の範囲外のサンプルは端に丸め、NaN は無音にする。
/// 長さやチェックサムは持たないため、読み込みで検出できる壊れは、ヘッダの不正と奇数バイトの長さだけ。
/// 予約の3バイトは読み込みでは見ない。
public struct RecordedAudio: Hashable, Sendable {
  /// 形式の識別子
  static let magic = Array("UTAU".utf8)
  /// 形式の版。形式を変えたら上げ、古い版を読めるかを `init(decoding:)` で判断する
  static let version: UInt8 = 1
  /// 識別子4バイト、版1バイト、予約3バイト、サンプリング周波数4バイト（リトルエンディアン）
  static let headerSize = 12

  /// サンプリング周波数（Hz）
  public let sampleRate: Int
  private var samples: [Int16]

  /// 空の録音を作る。
  /// - Throws: サンプリング周波数が 0 以下、または保存形式で表せない場合
  public init(sampleRate: Int) throws(RecordedAudioError) {
    guard sampleRate > 0, sampleRate <= Int(UInt32.max) else { throw .invalidSampleRate }
    self.sampleRate = sampleRate
    samples = []
  }

  /// 保存したバイト列から戻す。
  /// - Throws: 形式の識別子・版が違う場合は `unsupportedFormat`、長さやサンプリング周波数が不正なら `corrupted`
  public init(decoding data: Data) throws(RecordedAudioError) {
    let bytes = [UInt8](data)
    guard bytes.count >= Self.headerSize, Array(bytes[0..<Self.magic.count]) == Self.magic,
      bytes[Self.magic.count] == Self.version
    else { throw .unsupportedFormat }
    let rate = (8..<12).reduce(UInt32(0)) { $0 | UInt32(bytes[$1]) << (8 * UInt32($1 - 8)) }
    guard rate > 0, (bytes.count - Self.headerSize).isMultiple(of: 2) else { throw .corrupted }
    sampleRate = Int(rate)
    samples = stride(from: Self.headerSize, to: bytes.count, by: 2).map {
      Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
    }
  }

  public var sampleCount: Int { samples.count }

  public var duration: Duration {
    .seconds(Double(samples.count) / Double(sampleRate))
  }

  /// 録音中のチャンクを足す。
  /// - Throws: チャンクのサンプリング周波数が録音と違う場合。そのチャンクは足さない
  public mutating func append(_ chunk: AudioChunk) throws(RecordedAudioError) {
    guard chunk.sampleRate == sampleRate else { throw .sampleRateMismatch }
    samples.append(contentsOf: chunk.samples.map(Self.quantize))
  }

  /// 一時音声として保存するバイト列。
  public func encoded() -> Data {
    var data = Data(capacity: Self.headerSize + samples.count * 2)
    data.append(contentsOf: Self.magic)
    data.append(contentsOf: [Self.version, 0, 0, 0])
    withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
    #if _endian(little)
      samples.withUnsafeBytes { data.append(contentsOf: $0) }
    #else
      samples.map(\.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
    #endif
    return data
  }

  /// WAV（RIFF、リニア PCM 16bit、モノラル）のバイト列。クラウド STT へ送る音声に使う（#60）。
  ///
  /// 一時保存の形式（`encoded()`）とは別で、`init(decoding:)` では読めない。
  /// WAV のヘッダで長さ（4 GiB 未満）や1秒あたりのバイト数を表せない場合は `nil`。
  public func wavEncoded() -> Data? {
    let dataSize = samples.count.multipliedReportingOverflow(by: 2)
    guard !dataSize.overflow, dataSize.partialValue <= Int(UInt32.max) - 36,
      sampleRate <= Int(UInt32.max / 2)
    else { return nil }
    var data = Data(capacity: 44 + dataSize.partialValue)
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + dataSize.partialValue))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))  // fmt チャンクの長さ
    append(UInt16(1))  // リニア PCM
    append(UInt16(1))  // モノラル
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 2))  // 1秒あたりのバイト数
    append(UInt16(2))  // 1サンプルのバイト数
    append(UInt16(16))  // ビット数
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(dataSize.partialValue))
    #if _endian(little)
      samples.withUnsafeBytes { data.append(contentsOf: $0) }
    #else
      samples.map(\.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
    #endif
    return data
  }

  /// 音声認識へ流し直すチャンク。`chunkDuration` ごとに区切り、最後のチャンクは短くなる。
  /// `chunkDuration` が1サンプルに満たなければ1サンプルずつ区切る。
  public func chunks(chunkDuration: Duration = .milliseconds(100)) -> [AudioChunk] {
    let size = chunkSize(for: chunkDuration)
    return stride(from: 0, to: samples.count, by: size).map { start in
      chunk(samples, start..<min(start + size, samples.count))
    }
  }

  /// すべてのチャンクを流して終わるストリーム。`SpeechRecognizer.recognize(_:session:)` に渡すと、
  /// 録音を最後まで終えたものとして認識する。
  ///
  /// 長い録音でも音声を二重に持たないよう、チャンクは受け手が読むたびに1つずつ作る。受け手が読むのをやめたら作らない。
  public func stream(chunkDuration: Duration = .milliseconds(100)) -> AsyncStream<AudioChunk> {
    let samples = samples
    let sampleRate = sampleRate
    let size = chunkSize(for: chunkDuration)
    let offset = Mutex(0)
    return AsyncStream {
      let range = offset.withLock { offset -> Range<Int>? in
        guard offset < samples.count else { return nil }
        let range = offset..<min(offset + size, samples.count)
        offset = range.upperBound
        return range
      }
      guard let range else { return nil }
      return AudioChunk(samples: samples[range].map(Self.dequantize), sampleRate: sampleRate)
    }
  }

  /// `chunkDuration` に収まるサンプル数。1サンプルに満たなければ 1。
  /// 浮動小数点の誤差で1サンプル少なくならないよう、整数で計算する
  private func chunkSize(for chunkDuration: Duration) -> Int {
    let (seconds, attoseconds) = chunkDuration.components
    let rate = Int128(sampleRate)
    let count = Int128(seconds) * rate + Int128(attoseconds) * rate / 1_000_000_000_000_000_000
    return Int(max(1, min(count, Int128(Int.max / 2))))
  }

  private func chunk(_ samples: [Int16], _ range: Range<Int>) -> AudioChunk {
    AudioChunk(samples: samples[range].map(Self.dequantize), sampleRate: sampleRate)
  }

  static func quantize(_ sample: Float) -> Int16 {
    guard !sample.isNaN else { return 0 }
    return Int16((min(max(sample, -1), 1) * Float(Int16.max)).rounded())
  }

  static func dequantize(_ sample: Int16) -> Float {
    max(-1, Float(sample) / Float(Int16.max))
  }
}

// 音声をログに出さないよう、文字列表現とリフレクションにはサンプル数と周波数だけを出す。
extension RecordedAudio: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "RecordedAudio(sampleCount: \(samples.count), sampleRate: \(sampleRate))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["sampleCount": samples.count, "sampleRate": sampleRate])
  }
}

/// 録音音声の保存・復元の失敗。音声は含めない。
public enum RecordedAudioError: Error, Hashable, Sendable {
  /// サンプリング周波数が 0 以下、または保存形式で表せない
  case invalidSampleRate
  /// 録音と違うサンプリング周波数のチャンクを足そうとした
  case sampleRateMismatch
  /// 形式の識別子・版が違う
  case unsupportedFormat
  /// 長さやサンプリング周波数が不正で、途中で壊れている
  case corrupted
}
