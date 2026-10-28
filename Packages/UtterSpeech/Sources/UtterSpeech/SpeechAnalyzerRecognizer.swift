import Foundation
import UtterCore

/// Apple SpeechAnalyzer / SpeechTranscriber による音声認識（4章）。
///
/// Phase 0（#48）の結果が決めるのは標準 STT をどちらにするかで、このアダプターは標準でも代替でも使う。
/// 使い方（暫定・確定結果の扱い、音声形式の変換、キャンセル）は Verification/SpeechAnalyzerProbe で確かめたものに合わせる。
///
/// - モデルは取得しない。未対応・未取得なら `failed(.modelUnavailable)` を流して終える。取得は `SpeechAnalyzerAssets.install()` を
///   利用者の明示的な操作で呼ぶ（PERM-03）
/// - 音声は `AudioChunkConverter` で SpeechAnalyzer の形式（`bestAvailableAudioFormat`）に変換して渡す
/// - 結果は `TranscriptionEventMapper` で `partial` / `confirmed` に変換し、音声の終わりで残りを確定させて
///   確定テキスト全体を `completed` で流す。確定されないまま残った末尾の暫定結果は `completed` の末尾に含める
///   （進め方は `TranscriptionRun`）
/// - 受け手がストリームを破棄したら `cancelAndFinishNow()` で止める
/// - 認識テキストはログにもエラーにも出さない
public struct SpeechAnalyzerRecognizer: SpeechRecognizer {
  /// 既定のロケール（日本語）
  public static let defaultLocale = Locale(identifier: "ja_JP")

  public let locale: Locale

  public init(locale: Locale = Self.defaultLocale) {
    self.locale = locale
  }

  public func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent> {
    let locale = locale
    return TranscriptionRun.events(audio: audio, session: session) {
      await SpeechAnalyzerSession.make(locale: locale)
    }
  }
}
