import Foundation
import Synchronization
import Testing
import UtterCore
import UtterSpeech

@testable import UtterAI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct OpenAISpeechRecognizerTests {
  typealias StubTransport = OpenAIProviderTests.StubTransport

  /// 同意状態を差し替えられる入れ物。呼ばれた回数も数える
  final class ConsentBox: Sendable {
    let states: Mutex<[ConsentState]>
    let calls = Mutex(0)

    /// 呼ばれるたびに `states` の先頭から返し、最後の1つは返し続ける
    init(_ states: ConsentState...) {
      self.states = Mutex(states)
    }

    func current() -> ConsentState {
      calls.withLock { $0 += 1 }
      return states.withLock { states in
        states.count > 1 ? states.removeFirst() : states[0]
      }
    }
  }

  static let speechGranted: ConsentState = {
    var consent = ConsentState()
    consent.grant(.transmission(.speechRecognition))
    return consent
  }()

  static let successBody =
    #"{"text":"明日の会議は10時からです","usage":{"type":"tokens","input_tokens":12,"input_token_details":{"text_tokens":0,"audio_tokens":12},"output_tokens":5,"total_tokens":17}}"#

  private let session = SessionID()
  private let october = try! YearMonth(year: 2026, month: 10)
  /// 16 Hz で 1 秒の音声
  private let oneSecond = AudioChunk(samples: Array(repeating: 0.25, count: 16), sampleRate: 16)
  // swift-format-ignore: NeverUseForceTry
  private let configuration = try! OpenAISpeechRecognizer.Configuration(
    model: "m", language: "ja")

  /// 1トークン 1 円の単価表と、上限 `limit` 円の予算を持つ BudgetGuard
  private func makeGuard(limit: Int = 100) throws -> BudgetGuard {
    let yen = try CostCurrency(code: "JPY")
    let estimator = CostEstimator(
      priceTable: try PriceTable(
        currency: yen, updatedOn: try CivilDate(year: 2026, month: 10, day: 1),
        prices: [
          try ModelPrice(
            model: "m", inputPerMillionTokens: Decimal(1_000_000),
            outputPerMillionTokens: Decimal(1_000_000))
        ]))
    return BudgetGuard(
      budget: try MonthlyBudget(limitAmount: Decimal(limit), currency: yen), estimator: estimator,
      ledger: MonthlyUsageLedger(currency: yen))
  }

  /// 音声1秒あたり入力 3・出力 1 トークン（4 円）を見込む
  private func recognizer(
    _ transport: any HTTPStreamingTransport,
    consent: ConsentBox = ConsentBox(OpenAISpeechRecognizerTests.speechGranted),
    sensitivity: SensitiveInputDecision = .allowedInput,
    budgetGuard: BudgetGuard? = nil,
    configuration: OpenAISpeechRecognizer.Configuration? = nil
  ) throws -> OpenAISpeechRecognizer {
    let october = october
    return OpenAISpeechRecognizer(
      apiKey: "sk-test-secret", configuration: configuration ?? self.configuration,
      consent: { consent.current() },
      sensitivity: { sensitivity },
      budget: SpeechRecognitionBudget(
        guard: try budgetGuard ?? makeGuard(),
        expectedUsagePerSecond: TokenUsage(inputTokens: 3, outputTokens: 1),
        currentMonth: { october }),
      transport: transport, makeBoundary: { "b0undary" })
  }

  private func run(
    _ recognizer: OpenAISpeechRecognizer, _ chunks: [AudioChunk]
  ) async -> [RecognitionEvent] {
    let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    for chunk in chunks {
      continuation.yield(chunk)
    }
    continuation.finish()
    var events: [RecognitionEvent] = []
    for await event in recognizer.recognize(audio, session: session) {
      events.append(event)
    }
    return events
  }

  // MARK: - 同意（AC-06）

  @Test(
    "AC-06: 音声送信の同意がなければ、録音を読まずに consentNotGranted で終え、外部送信は 0 件",
    .timeLimit(.minutes(1)),
    arguments: [
      ConsentState(),
      // 整形の同意（OpenAI を含む）では音声を送らない
      .refinementGranted(.chatGPT),
      {
        var consent = ConsentState()
        for scope in ConsentScope.allCases where scope != .transmission(.speechRecognition) {
          consent.grant(scope)
        }
        return consent
      }(),
      {
        var consent = OpenAISpeechRecognizerTests.speechGranted
        consent.revoke(.transmission(.speechRecognition))
        return consent
      }(),
    ])
  func noSendWithoutConsent(_ consent: ConsentState) async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let budgetGuard = try makeGuard()
    // 終わらない録音。読み続けたらテストが終わらない
    let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    continuation.yield(oneSecond)

    var events: [RecognitionEvent] = []
    for await event in try recognizer(
      transport, consent: ConsentBox(consent), budgetGuard: budgetGuard
    ).recognize(audio, session: session) {
      events.append(event)
    }

    #expect(events.map(\.kind) == [.failed(.consentNotGranted)])
    #expect(transport.requests.withLock { $0.isEmpty })
    #expect(await budgetGuard.ledger.spent(in: october) == 0)
    continuation.finish()
  }

  @Test("AC-06: 録音中に音声送信の同意を撤回したら送信しない")
  func noSendWhenRevokedDuringRecording() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    var revoked = Self.speechGranted
    revoked.revoke(.transmission(.speechRecognition))
    let consent = ConsentBox(Self.speechGranted, revoked)

    let events = await run(try recognizer(transport, consent: consent), [oneSecond])

    #expect(events.map(\.kind) == [.failed(.consentNotGranted)])
    #expect(consent.calls.withLock { $0 } == 2)
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  @Test("7章, AC-12: 録音中に入力先が機密入力になったら送信も予約もせず sensitiveInput で終える")
  func noSendWhenInputBecameSensitive() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let budgetGuard = try makeGuard()

    let events = await run(
      try recognizer(transport, sensitivity: .secureFieldInput, budgetGuard: budgetGuard),
      [oneSecond])

    #expect(events.map(\.kind) == [.failed(.sensitiveInput)])
    #expect(transport.requests.withLock { $0.isEmpty })
    #expect(await budgetGuard.ledger.spent(in: october) == 0)
  }

  // MARK: - 送信と応答

  @Test("#60: 録音の終わりまで溜めて1回だけ送信し、completed だけを1件流す")
  func sendsOnceAndCompletes() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let budgetGuard = try makeGuard()

    let events = await run(
      try recognizer(transport, budgetGuard: budgetGuard), [oneSecond, oneSecond])

    #expect(
      events == [
        RecognitionEvent(sessionID: session, sequence: 0, kind: .completed("明日の会議は10時からです"))
      ])
    #expect(transport.requests.withLock { $0.count } == 1)
    // 実際の使用量（12 + 5 トークン）で記録する（AI-05）
    #expect(await budgetGuard.ledger.spent(in: october) == 17)
  }

  @Test("CTX-03: multipart で録音の WAV とモデル名・応答形式・言語だけを OpenAI API へ送る")
  func buildsMultipartRequest() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    _ = await run(try recognizer(transport), [oneSecond])
    let sent = try #require(transport.requests.withLock { $0.first })

    #expect(sent.url == OpenAISpeechRecognizer.defaultEndpoint)
    #expect(sent.url?.host == "api.openai.com")
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "authorization") == "Bearer sk-test-secret")
    #expect(
      sent.value(forHTTPHeaderField: "content-type") == "multipart/form-data; boundary=b0undary")
    #expect(sent.value(forHTTPHeaderField: "accept") == "application/json")
    #expect(sent.timeoutInterval == 120)

    var audio = try RecordedAudio(sampleRate: 16)
    try audio.append(oneSecond)
    let wav = try #require(audio.wavEncoded())
    var expected = Data(
      """
      --b0undary\r
      Content-Disposition: form-data; name="model"\r
      \r
      m\r
      --b0undary\r
      Content-Disposition: form-data; name="response_format"\r
      \r
      json\r
      --b0undary\r
      Content-Disposition: form-data; name="language"\r
      \r
      ja\r
      --b0undary\r
      Content-Disposition: form-data; name="file"; filename="audio.wav"\r
      Content-Type: audio/wav\r
      \r

      """.utf8)
    expected.append(wav)
    expected.append(Data("\r\n--b0undary--\r\n".utf8))
    #expect(sent.httpBody == expected)
  }

  @Test("#60: 言語を設定しなければ送らない")
  func omitsLanguage() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    _ = await run(
      try recognizer(transport, configuration: try .init(model: "m")), [oneSecond])

    let body = try #require(transport.requests.withLock { $0.first?.httpBody })
    #expect(body.range(of: Data(#"name="language""#.utf8)) == nil)
    #expect(body.range(of: Data(#"name="model""#.utf8)) != nil)
  }

  @Test("#60: チャンクのない録音は送信せずに空の completed で終える")
  func emptyAudioDoesNotSend() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let budgetGuard = try makeGuard()

    let events = await run(
      try recognizer(transport, budgetGuard: budgetGuard),
      [AudioChunk(samples: [], sampleRate: 16)])

    #expect(events.map(\.kind) == [.completed("")])
    #expect(transport.requests.withLock { $0.isEmpty })
    #expect(await budgetGuard.ledger.spent(in: october) == 0)
  }

  @Test("AI-05: 応答に使用量がない（秒数課金のモデルなど）なら、見込みの量で記録する")
  func settlesWithExpectedUsageWithoutTokens() async throws {
    let transport = StubTransport(
      .response(
        status: 200, body: #"{"text":"こんにちは","usage":{"type":"duration","seconds":2}}"#,
        contentType: "application/json"))
    let budgetGuard = try makeGuard()

    let events = await run(
      try recognizer(transport, budgetGuard: budgetGuard),
      [AudioChunk(samples: Array(repeating: 0, count: 24), sampleRate: 16)])

    #expect(events.map(\.kind) == [.completed("こんにちは")])
    // 1.5 秒は 2 秒に切り上げ、(3 + 1) × 2 = 8 円
    #expect(await budgetGuard.ledger.spent(in: october) == 8)
  }

  // MARK: - 上限（REC-05）・予算（AI-04）

  @Test("REC-05: 音声の長さの上限を超えたら、それ以降を読まずに送信せず audioLimitExceeded で終える")
  func rejectsTooLongAudio() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let configuration = try OpenAISpeechRecognizer.Configuration(
      model: "m", maxAudioDuration: .seconds(2))

    let atLimit = await run(
      try recognizer(transport, configuration: configuration), [oneSecond, oneSecond])
    #expect(atLimit.map(\.kind) == [.completed("明日の会議は10時からです")])

    let over = await run(
      try recognizer(transport, configuration: configuration), [oneSecond, oneSecond, oneSecond])
    #expect(over.map(\.kind) == [.failed(.audioLimitExceeded)])
    #expect(transport.requests.withLock { $0.count } == 1)
  }

  @Test("REC-05: WAV のバイト数の上限を超えたら送信しない")
  func rejectsTooLargeAudio() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    // 1 秒（16 サンプル）の WAV は 44 + 32 バイト
    let configuration = try OpenAISpeechRecognizer.Configuration(model: "m", maxAudioBytes: 76)

    let atLimit = await run(try recognizer(transport, configuration: configuration), [oneSecond])
    #expect(atLimit.map(\.kind) == [.completed("明日の会議は10時からです")])

    let over = await run(
      try recognizer(transport, configuration: configuration),
      [oneSecond, AudioChunk(samples: [0], sampleRate: 16)])
    #expect(over.map(\.kind) == [.failed(.audioLimitExceeded)])
    #expect(transport.requests.withLock { $0.count } == 1)
  }

  @Test(
    "#60: サンプリング周波数が不正・途中で変わる音声は送信しない",
    arguments: [
      [AudioChunk(samples: [0], sampleRate: 0)],
      [AudioChunk(samples: [0], sampleRate: 16), AudioChunk(samples: [0], sampleRate: 8)],
    ])
  func rejectsInvalidSampleRate(_ chunks: [AudioChunk]) async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))

    let events = await run(try recognizer(transport), chunks)

    #expect(events.map(\.kind) == [.failed(.unsupportedAudioFormat)])
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  @Test("AI-04: 予算上限を超えるなら送信せず budgetExceeded で終える")
  func rejectsOverBudget() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    // 1 秒の見込みは 4 円
    let budgetGuard = try makeGuard(limit: 3)

    let events = await run(try recognizer(transport, budgetGuard: budgetGuard), [oneSecond])

    #expect(events.map(\.kind) == [.failed(.budgetExceeded)])
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  // MARK: - エラー（AI-06）

  @Test(
    "AI-06: HTTP ステータスとエラーの code を音声認識の失敗に対応づけ、拒否は予算から取り消す",
    arguments: [
      (401, "invalid_api_key", SpeechRecognitionError.authenticationExpired, 0),
      (429, "insufficient_quota", .quotaExceeded, 0),
      (429, "rate_limit_exceeded", .quotaExceeded, 0),
      (408, "timeout", .timeout, 4),
      (503, "server_error", .networkUnavailable, 4),
      (400, "invalid_request_error", .invalidResponse, 4),
      (413, "file_too_large", .invalidResponse, 4),
    ])
  func mapsErrorStatus(
    _ status: Int, _ code: String, _ expected: SpeechRecognitionError, _ spent: Int
  ) async throws {
    let body = #"{"error":{"message":"sk-test-secret","type":"x","code":"\#(code)"}}"#
    let transport = StubTransport(
      .response(status: status, body: body, contentType: "application/json"))
    let budgetGuard = try makeGuard()

    let events = await run(try recognizer(transport, budgetGuard: budgetGuard), [oneSecond])

    #expect(events.map(\.kind) == [.failed(expected)])
    #expect(await budgetGuard.ledger.spent(in: october) == Decimal(spent))
  }

  @Test(
    "AI-06: 送信部の失敗と解釈できない応答を対応づける",
    arguments: [
      (StubTransport.Reply.failure(.timedOut), SpeechRecognitionError.timeout),
      (.failure(.notConnectedToInternet), .networkUnavailable),
      (.cancellation, .networkUnavailable),
      (.response(status: 200, body: "<html>"), .invalidResponse),
      (
        .response(status: 200, body: #"{"text":"途中"#, failure: .networkConnectionLost),
        .networkUnavailable
      ),
    ])
  func mapsTransportFailure(
    _ reply: StubTransport.Reply, _ expected: SpeechRecognitionError
  ) async throws {
    let events = await run(try recognizer(StubTransport(reply)), [oneSecond])

    #expect(events.map(\.kind) == [.failed(expected)])
  }

  @Test("AI-06: 応答本文が受信量の上限を超えたら、残りを受信せずに invalidResponse にする")
  func rejectsTooLargeResponse() async throws {
    let transport = StubTransport(.endless("a"))
    let configuration = try OpenAISpeechRecognizer.Configuration(model: "m", maxResponseBytes: 64)

    let events = await run(try recognizer(transport, configuration: configuration), [oneSecond])

    #expect(events.map(\.kind) == [.failed(.invalidResponse)])
    #expect(transport.bytesRead.withLock { $0 } <= 65)
  }

  @Test("AI-06: 応答待ちが上限時間を超えたら timeout で終え、見込みの費用で記録する", .timeLimit(.minutes(1)))
  func timesOut() async throws {
    let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
    let budgetGuard = try makeGuard()
    let configuration = try OpenAISpeechRecognizer.Configuration(
      model: "m", requestTimeout: .milliseconds(50))

    let events = await run(
      try recognizer(
        OpenAIProviderTests.HangingTransport(entered: enteredContinuation),
        budgetGuard: budgetGuard, configuration: configuration),
      [oneSecond])

    #expect(events.map(\.kind) == [.failed(.timeout)])
    #expect(await budgetGuard.ledger.spent(in: october) == 4)
    _ = entered
  }

  @Test("REC-06: 受け手がストリームを破棄したら通信を止め、イベントを流さない", .timeLimit(.minutes(1)))
  func cancelsWhenStreamDropped() async throws {
    let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
    let budgetGuard = try makeGuard()
    let recognizer = try recognizer(
      OpenAIProviderTests.HangingTransport(entered: enteredContinuation), budgetGuard: budgetGuard)
    let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    continuation.yield(oneSecond)
    continuation.finish()
    let session = session

    let consumer = Task {
      var events: [RecognitionEvent] = []
      for await event in recognizer.recognize(audio, session: session) {
        events.append(event)
      }
      return events
    }
    for await _ in entered { break }
    consumer.cancel()

    #expect(await consumer.value.isEmpty)
    // 送信後のキャンセルは課金されている可能性があるため、見込みの費用で記録する（AI-05）。
    // 記録は認識の Task で行うため、終わるまで待つ
    while await budgetGuard.ledger.spent(in: october) == 0 {
      await Task.yield()
    }
    #expect(await budgetGuard.ledger.spent(in: october) == 4)
  }

  /// キャンセルを無視し、`release` が終わるまで戻らない送信部
  struct StuckTransport: HTTPStreamingTransport {
    let release: AsyncStream<Void>

    func bytes(for request: URLRequest) async throws -> (
      AsyncThrowingStream<UInt8, any Error>, HTTPURLResponse
    ) {
      let release = release
      await withCheckedContinuation { continuation in
        Task.detached {
          for await _ in release {}
          continuation.resume()
        }
      }
      throw URLError(.cancelled)
    }
  }

  @Test("AI-06: 送信部がキャンセルに応じなくても、上限時間で timeout を流して終える", .timeLimit(.minutes(1)))
  func timesOutWhenTransportIgnoresCancellation() async throws {
    let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
    defer { releaseContinuation.finish() }
    let budgetGuard = try makeGuard()
    let configuration = try OpenAISpeechRecognizer.Configuration(
      model: "m", requestTimeout: .milliseconds(50))

    let events = await run(
      try recognizer(
        StuckTransport(release: release), budgetGuard: budgetGuard, configuration: configuration),
      [oneSecond])

    #expect(events.map(\.kind) == [.failed(.timeout)])
    #expect(await budgetGuard.ledger.spent(in: october) == 4)
  }

  @Test("REC-06: 録音を溜めている途中で破棄されたら、予約も送信もせずに終える", .timeLimit(.minutes(1)))
  func cancelsWhileCollecting() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let budgetGuard = try makeGuard()
    let consent = ConsentBox(Self.speechGranted)
    let recognizer = try recognizer(transport, consent: consent, budgetGuard: budgetGuard)
    let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    continuation.yield(oneSecond)
    let session = session

    let consumer = Task {
      var events: [RecognitionEvent] = []
      for await event in recognizer.recognize(audio, session: session) {
        events.append(event)
      }
      return events
    }
    while consent.calls.withLock({ $0 }) == 0 {
      await Task.yield()
    }
    consumer.cancel()
    // 破棄の後に録音が終わっても送らない
    continuation.yield(oneSecond)
    continuation.finish()

    #expect(await consumer.value.isEmpty)
    #expect(transport.requests.withLock { $0.isEmpty })
    #expect(await budgetGuard.ledger.spent(in: october) == 0)
  }

  // MARK: - 設定・秘密情報

  @Test(
    "AI-02: 送信先は https の OpenAI API のホストに限る",
    arguments: [
      ("http://api.openai.com/v1/audio/transcriptions", .insecureEndpoint),
      ("https://example.com/v1/audio/transcriptions", .unexpectedHost),
      ("https://api.openai.com.example.com/v1/audio/transcriptions", .unexpectedHost),
      (
        "https://api.anthropic.com/v1/audio/transcriptions",
        OpenAISpeechRecognizerConfigurationError.unexpectedHost
      ),
    ])
  func restrictsHost(_ endpoint: String, _ expected: OpenAISpeechRecognizerConfigurationError) {
    #expect(throws: expected) {
      try OpenAISpeechRecognizer.Configuration(model: "m", endpoint: URL(string: endpoint)!)
    }
  }

  @Test("AI-02: OpenAI API のホストは大文字・小文字を区別せず受け付ける")
  func acceptsOpenAIHost() throws {
    let configuration = try OpenAISpeechRecognizer.Configuration(
      model: "m", endpoint: URL(string: "https://API.openai.com/v1/audio/transcriptions")!)
    #expect(configuration.endpoint.host?.lowercased() == "api.openai.com")
  }

  @Test("#60: 不正な設定値を拒否する")
  func rejectsInvalidConfiguration() {
    #expect(throws: OpenAISpeechRecognizerConfigurationError.emptyModel) {
      try OpenAISpeechRecognizer.Configuration(model: "")
    }
    #expect(throws: OpenAISpeechRecognizerConfigurationError.invalidModel) {
      try OpenAISpeechRecognizer.Configuration(model: "m\r\n--b0undary")
    }
    #expect(throws: OpenAISpeechRecognizerConfigurationError.invalidModel) {
      try OpenAISpeechRecognizer.Configuration(model: #"m""#)
    }
    for language in ["", "ja\r\n", "j a", String(repeating: "a", count: 17)] {
      #expect(throws: OpenAISpeechRecognizerConfigurationError.invalidLanguage) {
        try OpenAISpeechRecognizer.Configuration(model: "m", language: language)
      }
    }
    #expect(throws: OpenAISpeechRecognizerConfigurationError.nonPositiveRequestTimeout) {
      try OpenAISpeechRecognizer.Configuration(model: "m", requestTimeout: .zero)
    }
    #expect(throws: OpenAISpeechRecognizerConfigurationError.nonPositiveAudioLimit) {
      try OpenAISpeechRecognizer.Configuration(model: "m", maxAudioDuration: .zero)
    }
    #expect(throws: OpenAISpeechRecognizerConfigurationError.nonPositiveAudioLimit) {
      try OpenAISpeechRecognizer.Configuration(model: "m", maxAudioBytes: 0)
    }
    #expect(throws: OpenAISpeechRecognizerConfigurationError.nonPositiveMaxResponseBytes) {
      try OpenAISpeechRecognizer.Configuration(model: "m", maxResponseBytes: 0)
    }
  }

  @Test("#60: 既定の上限は最大録音時間 5 分（REC-05）と 25 MB")
  func defaultLimits() throws {
    let configuration = try OpenAISpeechRecognizer.Configuration(model: "m")
    #expect(configuration.maxAudioDuration == .seconds(300))
    #expect(configuration.maxAudioBytes == 25_000_000)
    #expect(configuration.language == nil)
  }

  @Test("AI-06: 文字列表現に API キーを含めない")
  func redactsAPIKey() throws {
    let recognizer = try recognizer(StubTransport(.failure(.notConnectedToInternet)))
    let outputs = [
      String(describing: recognizer), String(reflecting: recognizer),
      String(describing: Mirror(reflecting: recognizer).children.map(\.value)),
    ]
    for output in outputs {
      #expect(!output.contains("sk-test-secret"))
    }
  }

  @Test("AI-05: 見込みの使用量は秒を切り上げ、溢れたら上限にする")
  func expectedUsage() throws {
    let budget = SpeechRecognitionBudget(
      guard: try makeGuard(), expectedUsagePerSecond: TokenUsage(inputTokens: 3, outputTokens: 1),
      currentMonth: { try! YearMonth(year: 2026, month: 10) })
    #expect(budget.expectedUsage(for: .zero) == TokenUsage(inputTokens: 0, outputTokens: 0))
    #expect(
      budget.expectedUsage(for: .milliseconds(1)) == TokenUsage(inputTokens: 3, outputTokens: 1))
    #expect(budget.expectedUsage(for: .seconds(2)) == TokenUsage(inputTokens: 6, outputTokens: 2))
    let huge = SpeechRecognitionBudget(
      guard: try makeGuard(),
      expectedUsagePerSecond: TokenUsage(inputTokens: .max, outputTokens: 1),
      currentMonth: { try! YearMonth(year: 2026, month: 10) })
    #expect(huge.expectedUsage(for: .seconds(2)).inputTokens == .max)
  }
}
