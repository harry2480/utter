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

  @Test("4章: STT Worker のローダーは、指定したロケールの SpeechAnalyzer の認識器を返す（モデルは OS が管理し、軽量として扱う）")
  func loaderReturnsRecognizer() async throws {
    let loader = SpeechAnalyzerModelLoader(locale: Locale(identifier: "en_US"))
    #expect(loader.weight == .light)
    let recognizer = try await loader.load()
    let speechAnalyzer = try #require(recognizer as? SpeechAnalyzerRecognizer)
    #expect(speechAnalyzer.locale.identifier == "en_US")
    #expect(SpeechAnalyzerModelLoader().locale == SpeechAnalyzerRecognizer.defaultLocale)
  }

  @Test("PERM-03, #199: 解除する予約は、識別子・言語と地域・言語の順に探し、別の言語の予約は選ばない")
  func findsReservationForLocale() {
    let japan = Locale(identifier: "ja-JP")
    let english = Locale(identifier: "en-US")
    let japaneseOnly = Locale(identifier: "ja")
    let calendarVariant = Locale(identifier: "ja-JP-u-ca-japanese")

    let exact = SpeechAnalyzerAssets.reservation(matching: japan, in: [english, japan])
    #expect(exact == japan)
    // variant（言語と地域が同じで識別子が違う）を、言語だけが同じ予約より先に選ぶ
    let variant = SpeechAnalyzerAssets.reservation(
      matching: japan, in: [japaneseOnly, calendarVariant])
    #expect(variant == calendarVariant)
    let languageOnly = SpeechAnalyzerAssets.reservation(
      matching: japan, in: [english, japaneseOnly])
    #expect(languageOnly == japaneseOnly)
    #expect(SpeechAnalyzerAssets.reservation(matching: japan, in: [english]) == nil)
    #expect(SpeechAnalyzerAssets.reservation(matching: japan, in: []) == nil)
  }
}
