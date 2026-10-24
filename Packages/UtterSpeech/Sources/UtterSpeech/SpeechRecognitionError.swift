/// 音声認識の失敗の種類。認識テキストや音声は持たない。
public enum SpeechRecognitionError: Error, Hashable, Sendable, CaseIterable, Codable {
  /// モデルが未取得、またはロードできない
  case modelUnavailable
  /// 音声の形式（サンプリング周波数など）に対応していない
  case unsupportedAudioFormat
  /// 認識エンジンが異常終了した（STT Worker の終了など）
  case engineFailed
  /// メモリ不足などでロード・推論を抑止した
  case resourceLimited
}
