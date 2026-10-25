import Foundation
import Speech
import Testing

@testable import UtterSpeech

// OS のモデルと実機の音声に依存する認識そのものは単体テストしない（PR の「人の確認」で実機確認する）。
// ここではエラーの分類と取得状態の対応だけを確かめる。
struct SpeechAnalyzerRecognizerTests {
  private static func speechError(_ code: SFSpeechError.Code) -> NSError {
    NSError(domain: SFSpeechErrorDomain, code: code.rawValue)
  }

  @Test(
    "PERM-03: モデルの未取得・ロケールの割り当て失敗は modelUnavailable",
    arguments: [
      SFSpeechError.Code.noModel, .assetLocaleNotAllocated, .tooManyAssetLocalesAllocated,
      .cannotAllocateUnsupportedLocale,
    ])
  func classifiesModelErrors(_ code: SFSpeechError.Code) {
    #expect(TranscriptionRun.classify(Self.speechError(code)) == .modelUnavailable)
  }

  @Test(
    "REC-04: 音声形式の不一致は unsupportedAudioFormat",
    arguments: [SFSpeechError.Code.unexpectedAudioFormat, .incompatibleAudioFormats])
  func classifiesFormatErrors(_ code: SFSpeechError.Code) {
    #expect(TranscriptionRun.classify(Self.speechError(code)) == .unsupportedAudioFormat)
  }

  @Test("6章: 資源不足は resourceLimited")
  func classifiesResourceErrors() {
    #expect(
      TranscriptionRun.classify(Self.speechError(.insufficientResources))
        == .resourceLimited)
  }

  @Test("REC-04: それ以外の Speech のエラーと、別の種類のエラーは engineFailed")
  func classifiesOtherErrors() {
    #expect(
      TranscriptionRun.classify(Self.speechError(.moduleOutputFailed)) == .engineFailed)
    #expect(
      TranscriptionRun.classify(Self.speechError(.internalServiceError)) == .engineFailed)
    #expect(
      TranscriptionRun.classify(NSError(domain: NSCocoaErrorDomain, code: 1))
        == .engineFailed)
  }

  @Test("REC-04: 分類済みのエラーはそのまま返す", arguments: SpeechRecognitionError.allCases)
  func keepsSpeechRecognitionError(_ error: SpeechRecognitionError) {
    #expect(TranscriptionRun.classify(error) == error)
  }

  @Test("PERM-03: アセットの状態を取得状態に対応させる")
  func mapsAssetStatus() {
    #expect(SpeechModelAvailability(.unsupported) == .unsupported)
    #expect(SpeechModelAvailability(.supported) == .notInstalled)
    #expect(SpeechModelAvailability(.downloading) == .downloading)
    #expect(SpeechModelAvailability(.installed) == .installed)
  }

  @Test("REC-06: 既定のロケールは日本語")
  func defaultsToJapanese() {
    #expect(SpeechAnalyzerRecognizer().locale.identifier == "ja_JP")
    #expect(SpeechAnalyzerAssets().locale.identifier == "ja_JP")
  }
}
