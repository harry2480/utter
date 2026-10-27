import Foundation
import Synchronization
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// OpenAI の音声認識 API への送信を数える送信部。実ネットワークには出ず、決めた応答を返す。
final class CountingStreamingTransport: HTTPStreamingTransport {
  private let text: String
  private let sent = Mutex<[URLRequest]>([])

  init(text: String = "明日の会議は10時からです") {
    self.text = text
  }

  /// 送られたリクエストの数
  var count: Int { sent.withLock { $0.count } }

  /// 送られたリクエストの送信先のホスト
  var hosts: [String?] { sent.withLock { $0.map { $0.url?.host } } }

  func bytes(for request: URLRequest) async throws -> (
    AsyncThrowingStream<UInt8, any Error>, HTTPURLResponse
  ) {
    sent.withLock { $0.append(request) }
    let body = #"{"text":"\#(text)","usage":{"type":"tokens","input_tokens":12,"output_tokens":5}}"#
    let url = try #require(request.url)
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: UInt8.self)
    for byte in Data(body.utf8) {
      continuation.yield(byte)
    }
    continuation.finish()
    return (stream, response)
  }
}

/// クラウド STT の条件（選択・同意・API キー・予算）をそろえた設定。
enum CloudSpeechRecognitionSettings {
  /// クラウド STT の条件がすべてそろった設定。音声1秒あたりの見込みの費用は
  /// `inputPrice` と `CloudSpeechRecognitionPipeline.expectedUsagePerSecond` で決まる
  static func ready(
    budgetLimit: Decimal = 10, inputPrice: Decimal = 1, priceModel: String? = nil
  ) -> AppSettings {
    var consent = ConsentState()
    consent.grant(.transmission(.speechRecognition))
    return AppSettings(
      cloudSpeechRecognitionEnabled: true,
      refinementMode: .raw,
      priceTable: PriceTableSetting(
        currencyCode: "USD", updatedOn: CalendarDay(year: 2026, month: 10, day: 1),
        prices: [
          ModelPriceSetting(
            model: priceModel ?? CloudSpeechRecognitionPipeline.model,
            inputPerMillionTokens: inputPrice, outputPerMillionTokens: 5)
        ].compactMap { $0 }),
      monthlyBudget: MonthlyBudgetSetting(limitAmount: budgetLimit, currencyCode: "USD"),
      consentState: consent)
  }

  /// 保存済みの OpenAI API キー
  static func apiKeyStore() -> StubAPIKeyStore {
    StubAPIKeyStore(key: try? APIKey("sk-test-openai-secret"))
  }

  /// Stub の送信部で送る認識器を作るクラウド STT
  @MainActor
  static func pipeline(
    store: AppSettingsStore,
    apiKeyStore: StubAPIKeyStore,
    database: UtterDatabase,
    transport: CountingStreamingTransport
  ) -> CloudSpeechRecognitionPipeline {
    CloudSpeechRecognitionPipeline(
      settingsStore: store, apiKeyStore: apiKeyStore, database: { database },
      makeRecognizer: { parts in
        OpenAISpeechRecognizer(
          apiKey: parts.apiKey.value, configuration: parts.configuration, consent: parts.consent,
          budget: parts.budget, transport: transport)
      },
      now: { RefinementSettings.now }, calendar: RefinementSettings.calendar)
  }
}
