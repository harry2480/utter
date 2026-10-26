import Foundation
import UtterCore

/// メインアプリから STT Worker へ送るメッセージ（4章 STT Worker, 13章）。
///
/// `SpeechRecognizer.recognize(_:session:)` と同じ形（音声チャンクを送り、`RecognitionEvent` を受け取る）を
/// XPC 越しに行うためのもの。音声と認識テキスト以外の秘密情報（API キー・トークン・本文以外の文脈）は載せない。
public enum STTWorkerRequest: Hashable, Sendable, Codable {
  /// セッションの認識を始める。Worker は `engine` のモデルをロードし（ロード済みなら使い回し）、
  /// 続く `audio` を認識する。同時に認識するのは1セッションまで（4章）
  case start(session: SessionID, engine: STTEngineKind)
  /// 認識中のセッションの音声
  case audio(session: SessionID, chunk: AudioChunk)
  /// 録音の終了。`SpeechRecognizer` に渡す音声のストリームの `finish()` にあたる
  case finishAudio(session: SessionID)
  /// 受け手がいなくなったセッションの認識を止める。終端イベントは返さない
  case cancel(session: SessionID)
  /// モデル保持の判定に使う設定と端末の状態（6章, AC-11）。変わるたびに送り直す
  case updateResources(STTWorkerResources)
}

/// STT Worker からメインアプリへ返すメッセージ。
public enum STTWorkerResponse: Hashable, Sendable, Codable {
  /// 認識イベント。セッションID と順序番号は Worker 内の認識器が付ける
  case event(RecognitionEvent)
}

/// STT Worker のモデル保持の判定に使う値（6章, AC-11）。
///
/// 設定（保持モード）と端末の状態（メモリ圧迫・低バッテリー）はメインアプリが持ち、Worker へ送る。
public struct STTWorkerResources: Hashable, Sendable, Codable {
  public let policy: ModelRetentionPolicy
  public let deviceState: DeviceResourceState

  public init(policy: ModelRetentionPolicy, deviceState: DeviceResourceState) {
    self.policy = policy
    self.deviceState = deviceState
  }
}

// MARK: - XPC で送るための Codable

// 音声・認識テキストを送るためのもので、ログや診断情報へ書き出す用途には使わない。
// 復号の失敗（DecodingError）も値を含めずに扱い、呼び出し側は種類だけを残す。

extension AudioChunk: Codable {
  private enum CodingKeys: String, CodingKey {
    case samples
    case sampleRate
  }

  /// サンプルは Float32 のビット列（リトルエンディアン）を連ねたバイト列で送る。
  /// 数値の配列として符号化するより小さく、速い
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let data = try container.decode(Data.self, forKey: .samples)
    let size = MemoryLayout<UInt32>.size
    guard data.count.isMultiple(of: size) else {
      throw DecodingError.dataCorruptedError(
        forKey: .samples, in: container, debugDescription: "サンプルのバイト数が Float32 の倍数でない")
    }
    let samples = data.withUnsafeBytes { buffer in
      (0..<buffer.count / size).map { index in
        Float(
          bitPattern: UInt32(
            littleEndian: buffer.loadUnaligned(fromByteOffset: index * size, as: UInt32.self)))
      }
    }
    self.init(samples: samples, sampleRate: try container.decode(Int.self, forKey: .sampleRate))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    #if _endian(little)
      // メモリ上の並びがそのまま送る形式なので、まとめて写す
      let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    #else
      var data = Data(capacity: samples.count * MemoryLayout<UInt32>.size)
      for sample in samples {
        withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
      }
    #endif
    try container.encode(data, forKey: .samples)
    try container.encode(sampleRate, forKey: .sampleRate)
  }
}

// RecognitionEvent・SpeechRecognitionError・ModelRetentionMode・MemoryPressure・DeviceResourceState は、
// 合成した Codable を各型の宣言に付けている。

extension ModelRetentionPolicy: Codable {
  private enum CodingKeys: String, CodingKey {
    case mode
    case balancedRetention
    case performanceRetentionAllowed
  }

  /// `init(mode:balancedRetention:performanceRetentionAllowed:)` と同じ検証を通す
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      mode: container.decode(ModelRetentionMode.self, forKey: .mode),
      balancedRetention: container.decode(Duration.self, forKey: .balancedRetention),
      performanceRetentionAllowed: container.decode(Bool.self, forKey: .performanceRetentionAllowed)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encode(balancedRetention, forKey: .balancedRetention)
    try container.encode(performanceRetentionAllowed, forKey: .performanceRetentionAllowed)
  }
}

// 音声・認識テキストをログに出さないよう、文字列表現とリフレクションには種類とセッションの有無だけを出す。
extension STTWorkerRequest: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .start(_, let engine): "start(engine: \(engine.rawValue))"
    case .audio(_, let chunk): "audio(\(chunk))"
    case .finishAudio: "finishAudio"
    case .cancel: "cancel"
    case .updateResources: "updateResources"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}

extension STTWorkerResponse: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .event(let event): "event(\(event))"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
