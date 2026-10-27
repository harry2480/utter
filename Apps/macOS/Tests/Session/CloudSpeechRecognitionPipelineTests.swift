import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// クラウド STT の準備（4章, AC-06, AI-04, AI-05, #188）。
/// OpenAI の音声認識 API への送信は数えるだけの送信部に置き換え、ネットワークに出ない。
@MainActor
struct CloudSpeechRecognitionPipelineTests {
  private let suite: TestDefaults
  private let database: UtterDatabase

  /// 機密入力に当たらない入力先の判定
  nonisolated static let allowedInput = SensitiveInputPolicy().decide(
    SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.editor"))

  init() throws {
    suite = try TestDefaults()
    database = try UtterDatabase.inMemory()
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: suite.defaults) }

  private func pipeline(
    _ settings: AppSettings,
    apiKeyStore: StubAPIKeyStore = CloudSpeechRecognitionSettings.apiKeyStore(),
    transport: CountingStreamingTransport
  ) throws -> CloudSpeechRecognitionPipeline {
    try store.save(settings)
    return CloudSpeechRecognitionSettings.pipeline(
      store: store, apiKeyStore: apiKeyStore, database: database, transport: transport)
  }

  /// 1秒の音声で認識し、流れたイベントを返す
  private func recognize(_ recognizer: any SpeechRecognizer) async -> [RecognitionEvent.Kind] {
    let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    continuation.yield(
      AudioChunk(samples: Array(repeating: 0.25, count: 16_000), sampleRate: 16_000))
    continuation.finish()
    var kinds: [RecognitionEvent.Kind] = []
    for await event in recognizer.recognize(audio, session: SessionID()) {
      kinds.append(event.kind)
    }
    return kinds
  }

  @Test("4章, #188: クラウド STT は既定で選ばれていない")
  func notSelectedByDefault() throws {
    let transport = CountingStreamingTransport()
    let pipeline = try pipeline(AppSettings(), transport: transport)

    #expect(!pipeline.isSelected)
    #expect(transport.count == 0)
  }

  @Test("4章, AC-06, AI-05: 同意・API キー・予算がそろえば OpenAI へ1回だけ送り、推定費用を整形と同じ累計に記録する")
  func sendsWhenEverythingIsReady() async throws {
    let transport = CountingStreamingTransport()
    let pipeline = try pipeline(CloudSpeechRecognitionSettings.ready(), transport: transport)
    #expect(pipeline.isSelected)

    guard
      case .ready(let recognizer) = await pipeline.prepareRecognizer(sensitivity: {
        Self.allowedInput
      })
    else {
      Issue.record("クラウド STT の認識器を作れなかった")
      return
    }
    // 準備だけでは送らない
    #expect(transport.count == 0)

    #expect(await recognize(recognizer) == [.completed("明日の会議は10時からです")])
    #expect(transport.count == 1)
    #expect(transport.hosts == ["api.openai.com"])
    #expect(try MonthlyUsageStore(database: database).entries().count == 1)
  }

  @Test(
    "AC-06: 音声の送信に同意していなければ、整形・選択テキストの送信に同意していても送らない",
    arguments: [
      ConsentState(),
      {
        var consent = ConsentState()
        for scope in ConsentScope.allCases where scope != .transmission(.speechRecognition) {
          consent.grant(scope)
        }
        return consent
      }(),
      {
        var consent = ConsentState()
        consent.grant(.transmission(.speechRecognition))
        consent.revoke(.transmission(.speechRecognition))
        return consent
      }(),
    ])
  func requiresSpeechRecognitionConsent(_ consent: ConsentState) async throws {
    var settings = CloudSpeechRecognitionSettings.ready()
    settings.consentState = consent
    let transport = CountingStreamingTransport()
    let pipeline = try pipeline(settings, transport: transport)

    #expect(
      await pipeline.prepareRecognizer(sensitivity: { Self.allowedInput }).unavailableReason
        == .consentNotGranted)
    #expect(transport.count == 0)
  }

  @Test("AC-06: 認識器を作った後に同意を撤回したら、送信の直前に確かめて送らない")
  func revokedConsentStopsSending() async throws {
    let transport = CountingStreamingTransport()
    let pipeline = try pipeline(CloudSpeechRecognitionSettings.ready(), transport: transport)
    guard
      case .ready(let recognizer) = await pipeline.prepareRecognizer(sensitivity: {
        Self.allowedInput
      })
    else {
      Issue.record("クラウド STT の認識器を作れなかった")
      return
    }

    var revoked = CloudSpeechRecognitionSettings.ready()
    revoked.consentState.revoke(.transmission(.speechRecognition))
    try store.save(revoked)

    #expect(await recognize(recognizer) == [.failed(.consentNotGranted)])
    #expect(transport.count == 0)
  }

  @Test("AC-12: OpenAI API キーが保存されていなければ送らない")
  func requiresAPIKey() async throws {
    let transport = CountingStreamingTransport()
    let pipeline = try pipeline(
      CloudSpeechRecognitionSettings.ready(), apiKeyStore: StubAPIKeyStore(), transport: transport)

    #expect(
      await pipeline.prepareRecognizer(sensitivity: { Self.allowedInput }).unavailableReason
        == .apiKeyNotSet)
    #expect(transport.count == 0)
  }

  @Test("AC-12: OpenAI API キーを読み出せなければ送らない")
  func unreadableAPIKey() async throws {
    let keys = CloudSpeechRecognitionSettings.apiKeyStore()
    keys.setFailure(.operationFailed(code: -25308), for: .load)
    let transport = CountingStreamingTransport()
    let pipeline = try pipeline(
      CloudSpeechRecognitionSettings.ready(), apiKeyStore: keys, transport: transport)

    #expect(
      await pipeline.prepareRecognizer(sensitivity: { Self.allowedInput }).unavailableReason
        == .apiKeyUnavailable)
    #expect(transport.count == 0)
  }

  @Test("AI-04, AI-05: 月次予算が未設定なら送らない")
  func requiresBudget() async throws {
    var settings = CloudSpeechRecognitionSettings.ready()
    settings.monthlyBudget = nil
    let transport = CountingStreamingTransport()
    let pipeline = try pipeline(settings, transport: transport)

    #expect(
      await pipeline.prepareRecognizer(sensitivity: { Self.allowedInput }).unavailableReason
        == .budgetUnavailable)
    #expect(transport.count == 0)
  }

  @Test("AI-05: 単価表にクラウド STT のモデルの単価がなければ送らない")
  func requiresModelPrice() async throws {
    let transport = CountingStreamingTransport()
    let pipeline = try pipeline(
      CloudSpeechRecognitionSettings.ready(priceModel: AppSettings.defaultRefinementModel),
      transport: transport)

    #expect(
      await pipeline.prepareRecognizer(sensitivity: { Self.allowedInput }).unavailableReason
        == .budgetUnavailable)
    #expect(transport.count == 0)
  }

  @Test("AI-04: 見込み費用が予算の上限を超えるなら、送らずに予算超過で終える")
  func budgetExceeded() async throws {
    let transport = CountingStreamingTransport()
    // 音声1秒で入力 20 トークン × 100万トークンあたり 100万ドル = 20 ドルを見込む（上限 10 ドル）
    let pipeline = try pipeline(
      CloudSpeechRecognitionSettings.ready(budgetLimit: 10, inputPrice: 1_000_000),
      transport: transport)
    guard
      case .ready(let recognizer) = await pipeline.prepareRecognizer(sensitivity: {
        Self.allowedInput
      })
    else {
      Issue.record("クラウド STT の認識器を作れなかった")
      return
    }

    #expect(await recognize(recognizer) == [.failed(.budgetExceeded)])
    #expect(transport.count == 0)
    #expect(try MonthlyUsageStore(database: database).entries().isEmpty)
  }

  @Test("4章, AI-06: クラウド STT の失敗の種類を HUD の理由にし、ローカルのエンジンの失敗では理由を出さない")
  func mapsFailureToNotice() {
    #expect(CloudSpeechRecognitionNotice(.consentNotGranted) == .consentNotGranted)
    #expect(CloudSpeechRecognitionNotice(.budgetExceeded) == .budgetExceeded)
    #expect(CloudSpeechRecognitionNotice(.networkUnavailable) == .networkUnavailable)
    #expect(CloudSpeechRecognitionNotice(.authenticationExpired) == .authenticationExpired)
    #expect(CloudSpeechRecognitionNotice(.engineFailed) == nil)
    #expect(CloudSpeechRecognitionNotice(.modelUnavailable) == nil)
  }
}

extension CloudSpeechRecognitionPreparation {
  /// 送らない理由。認識器を作ったら `nil`
  var unavailableReason: CloudSpeechRecognitionNotice? {
    switch self {
    case .ready: nil
    case .unavailable(let reason): reason
    }
  }
}
