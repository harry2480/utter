/// WhisperKit アダプターの設定（4章, PERM-03）。
///
/// Phase 0 #49（モデル選定）の判定待ちの先行実装（ライセンスは #47 の D-2 で採用可）のため、既定で無効（`isEnabled == false`）。
/// 無効のまま認識を始めると、音声を読まずに `failed(.modelUnavailable)` で終える。
///
/// 値はすべて仮置き。#49 の実測で決め直す。
/// - `transcriptionInterval`：WhisperKit の `AudioStreamTranscriber` が新しい音声を1秒ためてから推論するのに合わせた
/// - `requiredSegmentsForConfirmation`：同じく `AudioStreamTranscriber` の既定値（末尾の2区間を未確定として残す）
/// - `language`：日本語を指定し、言語判定はしない（WhisperKitProbe の計測と同じ）
public struct WhisperKitRecognizerConfiguration: Hashable, Sendable {
  /// WhisperKit が受け付けるサンプリング周波数（Hz）。`WhisperKit.sampleRate` と同じ値
  public static let sampleRate = 16_000

  /// 仮置きのモデル名。WhisperKitProbe の候補（`argmaxinc/whisperkit-coreml` のフォルダ名）のうち最小の多言語モデル。
  /// 採用するモデルは #49 で決める
  public static let provisionalModelName = "openai_whisper-tiny"

  /// `transcriptionInterval` の上限。Whisper が一度に扱う音声の長さ（30秒）に合わせる
  public static let maximumTranscriptionInterval: Duration = .seconds(30)

  /// 明示的に有効にしたときだけ認識する。既定は無効
  public let isEnabled: Bool
  /// 推論で指定する言語（Whisper の言語コード）
  public let language: String
  /// 暫定結果を出すために推論し直す間隔（新しく届いた音声の長さ）
  public let transcriptionInterval: Duration
  /// 推論結果の末尾で未確定として残す区間の数。これより前の区間を確定にする
  public let requiredSegmentsForConfirmation: Int

  public init(
    isEnabled: Bool = false,
    language: String = "ja",
    transcriptionInterval: Duration = .seconds(1),
    requiredSegmentsForConfirmation: Int = 2
  ) throws(WhisperKitRecognizerConfigurationError) {
    guard !language.isEmpty else {
      throw .emptyLanguage
    }
    guard transcriptionInterval > .zero else {
      throw .nonPositiveTranscriptionInterval
    }
    guard transcriptionInterval <= Self.maximumTranscriptionInterval else {
      throw .transcriptionIntervalTooLong
    }
    guard requiredSegmentsForConfirmation >= 1 else {
      throw .nonPositiveRequiredSegments
    }
    self.init(
      validatedIsEnabled: isEnabled, language: language,
      transcriptionInterval: transcriptionInterval,
      requiredSegmentsForConfirmation: requiredSegmentsForConfirmation)
  }

  private init(
    validatedIsEnabled isEnabled: Bool, language: String, transcriptionInterval: Duration,
    requiredSegmentsForConfirmation: Int
  ) {
    self.isEnabled = isEnabled
    self.language = language
    self.transcriptionInterval = transcriptionInterval
    self.requiredSegmentsForConfirmation = requiredSegmentsForConfirmation
  }

  /// 既定値の設定（無効）。値は `init` の既定値と同じ
  public static let disabled = WhisperKitRecognizerConfiguration(
    validatedIsEnabled: false, language: "ja", transcriptionInterval: .seconds(1),
    requiredSegmentsForConfirmation: 2)

  /// 推論し直す間隔をサンプル数にしたもの（1以上）
  public var transcriptionIntervalSampleCount: Int {
    let (seconds, attoseconds) = transcriptionInterval.components
    let samples =
      Double(seconds) * Double(Self.sampleRate)
      + Double(attoseconds) / 1e18 * Double(Self.sampleRate)
    return max(1, Int(samples.rounded(.up)))
  }
}

public enum WhisperKitRecognizerConfigurationError: Error, Hashable, Sendable {
  case emptyLanguage
  case nonPositiveTranscriptionInterval
  /// `maximumTranscriptionInterval` を超えている
  case transcriptionIntervalTooLong
  case nonPositiveRequiredSegments
}
