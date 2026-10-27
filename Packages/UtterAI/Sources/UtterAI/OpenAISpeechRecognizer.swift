import Foundation
import UtterCore
import UtterSpeech

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// OpenAI API キー方式の音声認識 API によるクラウド STT（#60, 7章, AC-06, CTX-03）。
///
/// MVP 外（1.1節）の先行実装で、アプリからは組み立てておらず、既定では使われない。
/// 要件定義では送信先が決まっていないため、OpenAI の音声認識 API（`POST /v1/audio/transcriptions`）を仮置きで使う。
///
/// - 録音の終わり（`audio` の終わり）まで音声を溜め、WAV にして1回だけ送信する（一括認識）。再送しない。
///   アップロードが終わるまで結果が出ないため `partial` / `confirmed` は流さず、`completed` か `failed` を1回だけ流す
/// - 送るのは録音音声と、モデル名・言語・応答形式の設定値だけ。ウィンドウタイトル・入力欄の本文・URL・辞書語は送らない（CTX-03）
/// - クラウド STT への音声送信の同意（`.transmission(.speechRecognition)`）を、認識の開始時と送信の直前に確認し、
///   なければ送信せずに `failed(.consentNotGranted)` で終える。整形の同意（`.textRefinement`）では送らない（7章, AC-06）
/// - 送信先は OpenAI API のホストに限る（`OpenAIProvider` と同じ制限, AI-02）
/// - トークン課金のため、送信前に `BudgetGuard` で見込み費用を予約し、応答の使用量で確定する（AI-04, AI-05）
/// - 音声の長さ・サイズの上限を超えたら送信せずに `failed(.audioLimitExceeded)` で終える。
///   音声は録音側（`RecordedAudio`）に残っているため、ローカル STT での再認識などは呼び出し側が決める（REC-05）
/// - API キーとモデル名は呼び出し側から受け取り、保存しない（Keychain・設定はアプリの責務）
public struct OpenAISpeechRecognizer: SpeechRecognizer {
  public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

  public struct Configuration: Hashable, Sendable {
    /// モデル名（AI-07）。設定値として受け取り、廃止・改名に追従できるようにする。単価表の照合にも使う
    public let model: String
    /// 発話の言語（ISO 639-1 など）。`nil` なら送らず、自動判定に任せる
    public let language: String?
    public let endpoint: URL
    /// アップロードと応答待ちを合わせた上限時間
    public let requestTimeout: Duration
    /// 送信する音声の長さの上限。最大録音時間（REC-05）の暫定値 5 分にそろえる
    public let maxAudioDuration: Duration
    /// 送信する音声（WAV）のバイト数の上限
    public let maxAudioBytes: Int
    /// 応答本文のバイト数の上限。超えたら残りを受信せずに打ち切る
    public let maxResponseBytes: Int

    /// 上限時間の既定値（暫定）。5 分の音声のアップロードと認識を見込む
    public static let defaultRequestTimeout: Duration = .seconds(120)
    /// 音声の長さの上限の既定値。最大録音時間（REC-05）の暫定値
    public static let defaultMaxAudioDuration: Duration = .seconds(5 * 60)
    /// 音声のバイト数の上限の既定値（仮置き）。OpenAI の音声認識 API のファイルの上限 25 MB に合わせる。
    /// 16 kHz の PCM16 なら 5 分で約 9.6 MB、48 kHz なら約 4 分 20 秒で上限に達する
    public static let defaultMaxAudioBytes = 25 * 1000 * 1000
    /// 応答本文のバイト数の上限の既定値（暫定）
    public static let defaultMaxResponseBytes = 1 << 20

    /// - Throws: モデル名・言語が空か使えない文字を含む、上限・待ち時間が 0 以下、
    ///   エンドポイントが https でないか OpenAI API のホストでない場合
    public init(
      model: String,
      language: String? = nil,
      endpoint: URL = OpenAISpeechRecognizer.defaultEndpoint,
      requestTimeout: Duration = Configuration.defaultRequestTimeout,
      maxAudioDuration: Duration = Configuration.defaultMaxAudioDuration,
      maxAudioBytes: Int = Configuration.defaultMaxAudioBytes,
      maxResponseBytes: Int = Configuration.defaultMaxResponseBytes
    ) throws(OpenAISpeechRecognizerConfigurationError) {
      guard !model.isEmpty else { throw .emptyModel }
      // multipart の区切りや見出しを壊さないよう、制御文字・引用符を含む値を送らない
      guard Self.isFieldValue(model) else { throw .invalidModel }
      if let language {
        guard !language.isEmpty, language.count <= 16,
          language.unicodeScalars.allSatisfy({
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || $0 == "-"
          })
        else { throw .invalidLanguage }
      }
      guard requestTimeout > .zero else { throw .nonPositiveRequestTimeout }
      guard maxAudioDuration > .zero, maxAudioBytes > 0 else { throw .nonPositiveAudioLimit }
      guard maxResponseBytes > 0 else { throw .nonPositiveMaxResponseBytes }
      // API キーと音声を平文で送らない
      guard endpoint.scheme?.lowercased() == "https" else { throw .insecureEndpoint }
      // 同意は送信内容（音声）ごとに確認するため、OpenAI API 以外のホストへ音声と API キーを送らない（AC-06, AI-02）
      guard endpoint.host?.lowercased() == OpenAISpeechRecognizer.defaultEndpoint.host else {
        throw .unexpectedHost
      }
      self.model = model
      self.language = language
      self.endpoint = endpoint
      self.requestTimeout = requestTimeout
      self.maxAudioDuration = maxAudioDuration
      self.maxAudioBytes = maxAudioBytes
      self.maxResponseBytes = maxResponseBytes
    }

    private static func isFieldValue(_ value: String) -> Bool {
      !value.unicodeScalars.contains {
        $0.properties.generalCategory == .control || $0 == "\"" || $0 == "\\"
      }
    }
  }

  public let configuration: Configuration
  private let apiKey: String
  private let consent: @Sendable () async -> ConsentState
  private let sensitivity: @Sendable () async -> SensitiveInputDecision
  private let budget: SpeechRecognitionBudget
  private let transport: any HTTPStreamingTransport
  private let makeBoundary: @Sendable () -> String

  /// - Parameters:
  ///   - consent: 最新の同意状態を返す。認識の開始時と、予算の予約の前後（送信の直前）に呼び、音声送信の同意を確認する（AC-06）
  ///   - sensitivity: その時点の入力先で判定し直した結果（7章, AC-12）。予算の予約の前と、予約を待った後の送信の直前に呼び、
  ///     `allowsCloudTransmission` でなければ送信せずに（予約済みなら取り消して）`failed(.sensitiveInput)` で終える。
  ///     録音の開始時の判定は呼び出し側が行う
  ///   - budget: 予算上限の設定（AI-04, AI-05）。トークン課金の API のため、省略できない
  ///   - makeBoundary: multipart の区切り文字列。テストで固定するために注入できる
  public init(
    apiKey: String,
    configuration: Configuration,
    consent: @escaping @Sendable () async -> ConsentState,
    sensitivity: @escaping @Sendable () async -> SensitiveInputDecision,
    budget: SpeechRecognitionBudget,
    transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
    makeBoundary: @escaping @Sendable () -> String = { "utter-\(UUID().uuidString)" }
  ) {
    self.apiKey = apiKey
    self.configuration = configuration
    self.consent = consent
    self.sensitivity = sensitivity
    self.budget = budget
    self.transport = transport
    self.makeBoundary = makeBoundary
  }

  public func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent> {
    // 流すイベントは終端の1件だけのため、バッファは無制限でよい
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    let task = Task {
      defer { continuation.finish() }
      // キャンセル（受け手がストリームを破棄）されたら何も流さない
      guard let kind = await transcribe(audio), !Task.isCancelled else { return }
      continuation.yield(RecognitionEvent(sessionID: session, sequence: 0, kind: kind))
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  /// 音声を溜めて送信し、終端イベントの種類を返す。キャンセルされたら `nil`
  func transcribe(_ audio: AsyncStream<AudioChunk>) async -> RecognitionEvent.Kind? {
    // 同意がなければ録音を読まずに終え、録音側に止めさせる
    guard await consent().allows(.speechRecognition) else {
      return .failed(.consentNotGranted)
    }
    let recorded: RecordedAudio?
    switch await collect(audio) {
    case .success(let value): recorded = value
    case .failure(let error): return .failed(error)
    }
    if Task.isCancelled {
      return nil
    }
    // 無音の録音（チャンクなし）は送らない。費用をかけずに空の結果で終える
    guard let recorded, recorded.sampleCount > 0 else {
      return .completed("")
    }
    // 1秒あたりのバイト数を WAV で表せない周波数は形式の不正。長さは `collect` で上限を確認済み
    guard let wav = recorded.wavEncoded() else {
      return .failed(.unsupportedAudioFormat)
    }
    guard wav.count <= configuration.maxAudioBytes else {
      return .failed(.audioLimitExceeded)
    }
    // 録音中に撤回されていたら送らない
    guard await consent().allows(.speechRecognition) else {
      return .failed(.consentNotGranted)
    }
    // 録音中に入力先が機密入力になっていたら送らない（7章, AC-12）
    guard await sensitivity().allowsCloudTransmission else {
      return .failed(.sensitiveInput)
    }

    let reservation: BudgetReservation
    do {
      reservation = try await budget.guard.reserve(
        model: configuration.model, expectedUsage: budget.expectedUsage(for: recorded.duration),
        in: budget.currentMonth())
    } catch {
      return Task.isCancelled ? nil : .failed(.budgetExceeded)
    }
    // 予約を待つ間にキャンセルされたら、送信せずに予約を取り消す
    if Task.isCancelled {
      await budget.guard.cancel(reservation)
      return nil
    }
    // 予約を待つ間に同意を撤回された・入力先が機密入力になっていたら、送信せずに予約を取り消す
    guard await consent().allows(.speechRecognition) else {
      await budget.guard.cancel(reservation)
      return .failed(.consentNotGranted)
    }
    guard await sensitivity().allowsCloudTransmission else {
      await budget.guard.cancel(reservation)
      return .failed(.sensitiveInput)
    }

    let result = await sendWithTimeout(makeURLRequest(wav: wav))
    await budget.guard.resolve(reservation, with: result.map(\.usage))
    if Task.isCancelled {
      return nil
    }
    switch result {
    case .success(let transcription):
      return .completed(transcription.text)
    case .failure(let error):
      return .failed(Self.recognitionError(error))
    }
  }

  /// 録音の終わりまで音声を溜める。チャンクがなければ `nil`。上限を超えたら、それ以降は読まない
  private func collect(
    _ audio: AsyncStream<AudioChunk>
  ) async -> Result<RecordedAudio?, SpeechRecognitionError> {
    var recorded: RecordedAudio?
    for await chunk in audio {
      if Task.isCancelled {
        break
      }
      if chunk.samples.isEmpty {
        continue
      }
      do {
        if recorded == nil {
          recorded = try RecordedAudio(sampleRate: chunk.sampleRate)
        }
        try recorded?.append(chunk)
      } catch {
        // サンプリング周波数が不正、または途中で変わった
        return .failure(.unsupportedAudioFormat)
      }
      if let recorded,
        recorded.duration > configuration.maxAudioDuration
          || Self.wavHeaderSize + recorded.sampleCount * 2 > configuration.maxAudioBytes
      {
        return .failure(.audioLimitExceeded)
      }
    }
    return .success(recorded)
  }

  private static let wavHeaderSize = 44

  func makeURLRequest(wav: Data) -> URLRequest {
    let boundary = makeBoundary()
    var request = URLRequest(url: configuration.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = configuration.requestTimeout.timeInterval
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")

    var body = Data()
    func appendField(_ name: String, _ value: String) {
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
      body.append(Data("\(value)\r\n".utf8))
    }
    appendField("model", configuration.model)
    appendField("response_format", "json")
    if let language = configuration.language {
      appendField("language", language)
    }
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
    body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
    body.append(wav)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    request.httpBody = body
    return request
  }

  /// 送信と上限時間を競わせ、先に決まった方を返す。
  ///
  /// 上限時間を過ぎたら、送信部がキャンセルに応じなくても待たずに戻る（`RefinementRouter` と同じ）。
  /// 呼び出し元がキャンセルされた場合は `.cancelled` を返す。
  private func sendWithTimeout(_ request: URLRequest) async -> Result<
    Transcription, AIProviderError
  > {
    let race = Race<Transcription>()
    let transport = transport
    let timeout = configuration.requestTimeout
    let maxResponseBytes = configuration.maxResponseBytes
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        race.install(continuation)
        race.add(
          Task {
            do throws(AIProviderError) {
              race.finish(
                .success(
                  try await Self.send(request, over: transport, maxResponseBytes: maxResponseBytes))
              )
            } catch {
              race.finish(.failure(error))
            }
          })
        race.add(
          Task {
            try? await Task.sleep(for: timeout)
            race.finish(.failure(.timeout))
          })
      }
    } onCancel: {
      race.finish(.failure(.cancelled))
    }
  }

  /// 送信部の型を開いて送信し、応答を読む
  private static func send<Transport: HTTPStreamingTransport>(
    _ request: URLRequest,
    over transport: Transport,
    maxResponseBytes: Int
  ) async throws(AIProviderError) -> Transcription {
    let bytes: Transport.Bytes
    let response: HTTPURLResponse
    do {
      (bytes, response) = try await transport.bytes(for: request)
    } catch {
      if Task.isCancelled {
        throw .cancelled
      }
      throw AIProviderError(transportError: error)
    }
    var reader = LineReader(bytes.makeAsyncIterator(), byteLimit: maxResponseBytes)
    let body: Data?
    let failure: AIProviderError?
    do {
      (body, failure) = (try await reader.readAll(), nil)
    } catch {
      switch error {
      case .exceeded:
        (body, failure) = (nil, .invalidResponse)
      case .transport(let error):
        (body, failure) = (
          nil, Task.isCancelled ? .cancelled : AIProviderError(transportError: error)
        )
      }
    }

    guard (200..<300).contains(response.statusCode) else {
      // エラー本文が上限を超えたり途中で切れたりしても、HTTP ステータスで対応づける
      let code = body.flatMap { try? JSONDecoder().decode(ResponsesErrorResponse.self, from: $0) }?
        .error
      throw OpenAIProvider.mapStatus(response.statusCode, errorCode: code?.code ?? code?.type)
    }
    if let failure {
      throw failure
    }
    guard let body, let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: body)
    else {
      throw .invalidResponse
    }
    return Transcription(text: decoded.text, usage: decoded.usage?.tokenUsage)
  }

  /// 送信の失敗を音声認識の失敗に対応づける（AI-06 と同じ分け方）
  static func recognitionError(_ error: AIProviderError) -> SpeechRecognitionError {
    switch error {
    case .timeout: .timeout
    case .authenticationExpired: .authenticationExpired
    case .quotaExceeded: .quotaExceeded
    case .budgetExceeded: .budgetExceeded
    case .invalidResponse: .invalidResponse
    // 呼び出し元はキャンセルしていないのに送信部がキャンセルした。届かなかったものとして扱う
    case .networkUnavailable, .cancelled: .networkUnavailable
    }
  }

  struct Transcription: Sendable {
    let text: String
    let usage: TokenUsage?
  }
}

/// クラウド STT の予算上限の設定（AI-04, AI-05）。
///
/// 送信前に音声の長さから見込みの使用量を計算して `BudgetGuard` に予約し、応答の使用量で確定する。
/// 使用量が応答に含まれない（読めない）場合は、課金されている可能性があるため見込みの量で記録する。
/// 単価は `BudgetGuard` の単価表（利用者の設定）で、モデル名（`OpenAISpeechRecognizer.Configuration.model`）で照合する。
public struct SpeechRecognitionBudget: Sendable {
  public let `guard`: BudgetGuard
  /// 音声1秒あたりの見込みのトークン使用量（入力は音声トークン、出力は認識テキスト）。
  /// 応答の使用量がわからない場合はこの量で記録するため、少なめに見積もらない
  public let expectedUsagePerSecond: TokenUsage
  /// 費用を計上する月。送信の直前に呼ぶ
  public let currentMonth: @Sendable () -> YearMonth

  public init(
    guard: BudgetGuard,
    expectedUsagePerSecond: TokenUsage,
    currentMonth: @escaping @Sendable () -> YearMonth
  ) {
    self.guard = `guard`
    self.expectedUsagePerSecond = expectedUsagePerSecond
    self.currentMonth = currentMonth
  }

  /// `duration` の音声の見込みの使用量。秒は切り上げる
  func expectedUsage(for duration: Duration) -> TokenUsage {
    let (seconds, attoseconds) = duration.components
    let roundedSeconds = Int(clamping: seconds + (attoseconds > 0 ? 1 : 0))
    func scaled(_ perSecond: Int) -> Int {
      let (value, overflow) = perSecond.multipliedReportingOverflow(by: roundedSeconds)
      return overflow ? .max : value
    }
    return TokenUsage(
      inputTokens: scaled(expectedUsagePerSecond.inputTokens),
      outputTokens: scaled(expectedUsagePerSecond.outputTokens))
  }
}

/// `OpenAISpeechRecognizer.Configuration` の不正な値。
public enum OpenAISpeechRecognizerConfigurationError: Error, Hashable, Sendable {
  case emptyModel
  /// 制御文字・引用符を含むモデル名
  case invalidModel
  /// 空、長すぎる、または英字とハイフン以外を含む言語
  case invalidLanguage
  case nonPositiveRequestTimeout
  /// 音声の長さ・バイト数の上限が 0 以下
  case nonPositiveAudioLimit
  case nonPositiveMaxResponseBytes
  /// https 以外のエンドポイント
  case insecureEndpoint
  /// OpenAI API 以外のホストのエンドポイント
  case unexpectedHost
}

// API キーをログに出さないよう、文字列表現とリフレクションにはモデル名だけを出す。
extension OpenAISpeechRecognizer: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "OpenAISpeechRecognizer(model: \(configuration.model))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["model": configuration.model])
  }
}

// MARK: - 音声認識 API の形式

/// `response_format=json` の応答
struct TranscriptionResponse: Decodable {
  /// トークン課金のモデルの使用量。秒数で課金するモデルは `type` が `duration` で、トークン数を持たない
  struct Usage: Decodable {
    let inputTokens: Int
    let outputTokens: Int

    var tokenUsage: TokenUsage {
      TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
    }
  }

  let text: String
  let usage: Usage?

  enum CodingKeys: String, CodingKey {
    case text
    case usage
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    text = try container.decode(String.self, forKey: .text)
    // 使用量の形が読めなければ `nil` にし、見込みの量で記録させる（AI-05）
    usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
  }
}
