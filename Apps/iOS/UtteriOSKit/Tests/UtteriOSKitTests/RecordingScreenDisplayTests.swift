import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

@testable import UtteriOSKit

/// ホーム・録音中・結果の画面に出す表示の値（#201）。
struct RecordingScreenDisplayTests {
  private func settings(engine: RefinementEngine, consented: Bool) -> AppSettings {
    var consent = ConsentState()
    if consented {
      consent.grant(.transmission(.textRefinement(.claude)))
    }
    return AppSettings(refinementEngine: engine, consentState: consent)
  }

  // MARK: 整形先・認識先

  @Test("AC-06: クラウド AI を選び Claude への送信に同意していれば、整形先を Claude にして「文字を送信」と示す")
  func cloudWithConsentSendsText() {
    let destination = ProcessingDestination(
      refinementFor: .natural, settings: settings(engine: .cloudAI, consented: true))

    #expect(destination.name == "Claude")
    #expect(destination.sendsText)
  }

  @Test(
    "AC-06: Local Basic を選んでいる・同意していない・Raw のときは「文字を送信」と示さない",
    arguments: [
      (RefinementMode.natural, RefinementEngine.localBasic, true),
      (RefinementMode.structured, RefinementEngine.cloudAI, false),
      (RefinementMode.raw, RefinementEngine.cloudAI, true),
    ])
  func localDestinationsDoNotSendText(
    mode: RefinementMode, engine: RefinementEngine, consented: Bool
  ) {
    let destination = ProcessingDestination(
      refinementFor: mode, settings: settings(engine: engine, consented: consented))

    #expect(!destination.sendsText)
  }

  @Test("TXT-01: Raw は整形しないことを示す")
  func rawIsUnrefined() {
    let destination = ProcessingDestination(
      refinementFor: .raw, settings: settings(engine: .cloudAI, consented: true))

    #expect(destination.name == "整形しない（Raw）")
  }

  @Test("AC-06: 同意していなければ、クラウド AI を選んでいても端末内で整形することを示す")
  func cloudWithoutConsentIsLocal() {
    let destination = ProcessingDestination(
      refinementFor: .natural, settings: settings(engine: .cloudAI, consented: false))

    #expect(destination.name == "Local Basic（Claude への送信に未同意）")
  }

  @Test("iOS-04: 認識先はどのエンジンでも端末内で、文字を送らない", arguments: SpeechEngineSelection.allCases)
  func speechDestinationIsOnDevice(_ engine: SpeechEngineSelection) {
    #expect(!ProcessingDestination(speechEngine: engine).sendsText)
  }

  @Test("iOS-04: STT が未設定なら、文字にしないことを示す")
  func unconfiguredSpeech() {
    #expect(ProcessingDestination(speechEngine: .unconfigured).name == "未設定（文字にしません）")
    #expect(ProcessingDestination(speechEngine: .speechAnalyzer).name == "SpeechAnalyzer（端末内）")
  }

  @Test("AC-06: Claude で整形した結果は「文字を送信」と示す")
  func cloudRouteSentText() {
    let destination = ProcessingDestination(refinementFor: .natural, route: .cloud)

    #expect(destination.name == "Claude")
    #expect(destination.sendsText)
  }

  @Test(
    "4.1節: 送信した後に端末内の整形へ切り替えた結果は「文字を送信」と示す",
    arguments: [
      RefinementFallbackReason.providerFailed(.timeout),
      .providerFailed(.networkUnavailable),
    ])
  func fallbackAfterSendingSentText(_ reason: RefinementFallbackReason) {
    let destination = ProcessingDestination(
      refinementFor: .natural, route: .cloudFallback(reason))

    #expect(destination.name == "Local Basic（Claude から切り替え）")
    #expect(destination.sendsText)
  }

  @Test(
    "AC-06, AC-12: 同意がない・機密入力で送らなかった結果は「文字を送信」と示さない",
    arguments: [RefinementFallbackReason.consentNotGranted, .sensitiveInputSuppressed])
  func fallbackWithoutSendingDidNotSendText(_ reason: RefinementFallbackReason) {
    let destination = ProcessingDestination(
      refinementFor: .natural, route: .cloudFallback(reason))

    #expect(!destination.sendsText)
  }

  @Test(
    "TXT-01: 送信しなかった結果は、端末内で整形したことを示す",
    arguments: [
      (RefinementMode.natural, SessionRefinementRoute.localOnly(.localEngineSelected)),
      (.structured, .localOnly(.cloudNotConfigured)),
      (.natural, .localOnly(.apiKeyNotSet)),
    ])
  func localRoutes(mode: RefinementMode, route: SessionRefinementRoute) {
    let destination = ProcessingDestination(refinementFor: mode, route: route)

    #expect(destination.name == "Local Basic（端末内）")
    #expect(!destination.sendsText)
  }

  @Test(
    "TXT-01: Raw の結果は整形しなかったことを示す",
    arguments: [
      SessionRefinementRoute.localOnly(.rawMode), .localOnly(.cloudNotConfigured),
    ])
  func rawRoutes(_ route: SessionRefinementRoute) {
    let destination = ProcessingDestination(refinementFor: .raw, route: route)

    #expect(destination.name == "整形しない（Raw）")
    #expect(!destination.sendsText)
  }

  // MARK: 文体

  @Test("TXT-01: 文体の名前は Raw / Natural / Structured")
  func styleNames() {
    #expect(RefinementMode.allCases.map(\.styleName) == ["Raw", "Natural", "Structured"])
  }

  @Test("TXT-01: 保存する文体と整形モードを相互に変換する", arguments: RefinementMode.allCases)
  func styleSettingRoundTrip(_ mode: RefinementMode) {
    #expect(RefinementMode(RefinementModeSetting(mode)) == mode)
  }

  // MARK: 録音時間

  @Test(
    "REC-05: 経過時間を「分:秒」で出す",
    arguments: [
      (Duration.zero, "0:00"),
      (.milliseconds(12_900), "0:12"),
      (.seconds(65), "1:05"),
      (.seconds(300), "5:00"),
      (.seconds(-3), "0:00"),
    ])
  func clockText(duration: Duration, text: String) {
    #expect(RecordingDurationText.clock(duration) == text)
  }

  @Test(
    "REC-05: ホームに最大録音時間を出す",
    arguments: [
      (Duration.seconds(300), "最大録音時間 5 分"),
      (.seconds(90), "最大録音時間 1 分 30 秒"),
      (.seconds(45), "最大録音時間 45 秒"),
    ])
  func maximumText(duration: Duration, text: String) {
    #expect(RecordingDurationText.maximum(duration) == text)
  }

  @Test("REC-05: 録音中は「経過 / 最大録音時間」を出す")
  func progressText() {
    let progress = RecordingProgress(elapsed: .seconds(12), maxDuration: .seconds(300))

    #expect(progress.text == "0:12 / 5:00")
    #expect(abs(progress.fraction - 0.04) < 1e-9)
  }

  @Test("REC-05: 経過時間は最大録音時間を超えて出さない")
  func progressIsClamped() {
    let progress = RecordingProgress(elapsed: .seconds(320), maxDuration: .seconds(300))

    #expect(progress.text == "5:00 / 5:00")
    #expect(progress.fraction == 1)
  }

  // MARK: 残り時間

  @Test(
    "iOS-IPC-02: 結果が消えるまでの残り時間を分に切り上げて出す",
    arguments: [
      (600.0, "あと 10 分で消えます"),
      (61.0, "あと 2 分で消えます"),
      (30.0, "あと 1 分で消えます"),
      (0.0, "期限が切れました"),
      (-10.0, "期限が切れました"),
    ])
  func remainingMessage(seconds: TimeInterval, message: String) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(
      ResultRemainingTime.message(until: now.addingTimeInterval(seconds), at: now) == message)
  }

  // MARK: 元のアプリへの戻り方

  @Test("iOS-03, iOS-07: キーボードと共有していれば、元のアプリに戻ってキーボードから入れる手順とコピーの案内を出す")
  func returnGuideWithKeyboard() {
    let guide = ResultReturnGuide(sharing: .appGroup)

    #expect(guide.steps.count == 3)
    #expect(guide.steps.contains { $0.contains("地球儀キー") })
    #expect(guide.copyHint.contains("コピー"))
  }

  @Test(
    "iOS-07: キーボードと共有していなければ、キーボードの手順を出さずにコピーを案内する",
    arguments: [
      SharedResultSharing.appLocalOnly(.appGroupNotConfigured),
      .appLocalOnly(.appGroupUnavailable),
    ])
  func returnGuideWithoutKeyboard(_ sharing: SharedResultSharing) {
    let guide = ResultReturnGuide(sharing: sharing)

    #expect(guide.steps.isEmpty)
    #expect(guide.copyHint.contains("コピー"))
  }

  // MARK: 途中の文字

  @Test("2.2節: 途中の文字は確定した部分と聞き取り中の部分を分ける")
  func interimSeparatesConfirmedAndListening() throws {
    var preview = TranscriptPreview()
    preview.apply(.confirmed("明日の会議は"))
    preview.apply(.partial("10時から"))

    let interim = try #require(InterimTranscript(preview))

    #expect(interim.confirmed == "明日の会議は")
    #expect(interim.listening == "10時から")
  }

  @Test("2.2節: STT が途中経過を返さなければ途中の文字を出さない")
  func interimIsAbsentWithoutPartials() {
    #expect(InterimTranscript(TranscriptPreview()) == nil)
  }

  @Test("ログの秘匿: 途中の文字の文字列表現とリフレクションに本文を出さない")
  func interimDoesNotExposeText() throws {
    var preview = TranscriptPreview()
    preview.apply(.partial("秘密の発話"))
    let interim = try #require(InterimTranscript(preview))

    #expect(!String(describing: interim).contains("秘密"))
    #expect(!String(reflecting: interim).contains("秘密"))
    #expect(Mirror(reflecting: interim).children.allSatisfy { !"\($0.value)".contains("秘密") })
  }
}
