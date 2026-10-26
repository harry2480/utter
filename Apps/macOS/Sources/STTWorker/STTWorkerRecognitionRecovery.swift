import UtterCore
import UtterSpeech

/// STT Worker の異常終了で失敗した認識だけを、録音音声でやり直す（7章, AC-10）。
///
/// 異常終了かどうかは `STTWorkerSpeechRecognizer.termination(of:)` で確かめる。起動の失敗・再起動の回数制限・
/// Worker が報告した失敗（エンジン自体の失敗）ではやり直さない。同じ音声で同じ失敗を繰り返すだけになるため。
struct STTWorkerRecognitionRecovery: SessionRecognitionRecovering {
  let recognizer: STTWorkerSpeechRecognizer

  func shouldRecognizeAgain(_ session: SessionID, after error: SpeechRecognitionError) async -> Bool
  {
    guard error == .engineFailed else { return false }
    return await recognizer.termination(of: session)?.canRestart == true
  }
}
