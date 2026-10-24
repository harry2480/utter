import UtterSpeech
import WhisperKit

/// WhisperKit の失敗を `SpeechRecognitionError` に分類する（4章）。
///
/// WhisperKit のエラーは文言を持つが、パスなどを含みうるため使わず、種類だけを返す。
enum WhisperKitErrorMapping {
  /// 失敗した処理
  enum Phase: Hashable, Sendable {
    /// モデルの検証・ロード
    case load
    /// 推論
    case transcribe
  }

  static func recognitionError(for error: any Error, during phase: Phase) -> SpeechRecognitionError
  {
    if let error = error as? SpeechRecognitionError {
      return error
    }
    if let error = error as? WhisperError {
      switch error {
      case .tokenizerUnavailable, .modelsUnavailable, .initializationError:
        return .modelUnavailable
      default:
        break
      }
    }
    // ロード中の失敗（Core ML のロード失敗などを含む）はモデルを使えない扱いにし、推論中の失敗はエンジンの異常にする
    switch phase {
    case .load: return .modelUnavailable
    case .transcribe: return .engineFailed
    }
  }
}
