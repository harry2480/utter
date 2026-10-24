import AVFoundation
import Speech

/// 認識エンジンの差し替え点。Apple の SpeechAnalyzer に固有のコードはこのファイルに閉じる。
/// WhisperKit などを足す場合は、同じ形（prepare / startStreaming / finishStreaming / recognize）
/// の型を追加し、ProbeModel から呼び分ける（README の「WhisperKit を足す場合」）。

enum EngineKind: String, CaseIterable, Identifiable, Sendable {
  /// 汎用の新しいモデル（対応端末が限られる。`SpeechTranscriber.isAvailable`）
  case speechTranscriber
  /// キーボードの音声入力と同じ系統のモデル（SpeechTranscriber 非対応端末の代替）
  case dictationTranscriber

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .speechTranscriber: "SpeechTranscriber"
    case .dictationTranscriber: "DictationTranscriber"
    }
  }
}

enum ModelRetentionOption: String, CaseIterable, Identifiable, Sendable {
  case whileInUse
  case lingering
  case processLifetime

  var id: String { rawValue }

  var value: SpeechAnalyzer.Options.ModelRetention {
    switch self {
    case .whileInUse: .whileInUse
    case .lingering: .lingering
    case .processLifetime: .processLifetime
    }
  }
}

struct EngineConfiguration: Sendable {
  var kind: EngineKind
  var locale: Locale
  /// 暫定結果（volatile）を受け取る
  var progressiveResults: Bool
  var retention: ModelRetentionOption
}

/// 認識モジュール。種類ごとに結果の型が違うため列挙で持つ。
enum TranscriberModule: Sendable {
  case speech(SpeechTranscriber)
  case dictation(DictationTranscriber)

  init(_ configuration: EngineConfiguration) {
    switch configuration.kind {
    case .speechTranscriber:
      self = .speech(
        SpeechTranscriber(
          locale: configuration.locale,
          preset: configuration.progressiveResults ? .progressiveTranscription : .transcription
        )
      )
    case .dictationTranscriber:
      self = .dictation(
        DictationTranscriber(
          locale: configuration.locale,
          preset: configuration.progressiveResults ? .progressiveShortDictation : .shortDictation
        )
      )
    }
  }

  var module: any SpeechModule {
    switch self {
    case .speech(let transcriber): transcriber
    case .dictation(let transcriber): transcriber
    }
  }
}

/// 対応状況とアセットの状態。
struct EngineAvailability: Sendable {
  var deviceSupported: Bool?
  var supportedLocale: Locale?
  var installedLocales: [Locale]
  /// AssetInventory.Status は Sendable でないため表示用の文字列で持つ
  var assetStatus: String?
  var reservedLocales: [Locale]
  var maximumReservedLocales: Int
}

enum SpeechEngineInfo {
  static func availability(for configuration: EngineConfiguration) async -> EngineAvailability {
    let supported: Locale?
    let installed: [Locale]
    let deviceSupported: Bool?
    switch configuration.kind {
    case .speechTranscriber:
      deviceSupported = SpeechTranscriber.isAvailable
      supported = await SpeechTranscriber.supportedLocale(equivalentTo: configuration.locale)
      installed = await SpeechTranscriber.installedLocales
    case .dictationTranscriber:
      deviceSupported = nil
      supported = await DictationTranscriber.supportedLocale(equivalentTo: configuration.locale)
      installed = await DictationTranscriber.installedLocales
    }
    var status: String?
    if let supported {
      var resolved = configuration
      resolved.locale = supported
      status = await AssetInventory.status(forModules: [TranscriberModule(resolved).module]).label
    }
    return EngineAvailability(
      deviceSupported: deviceSupported,
      supportedLocale: supported,
      installedLocales: installed,
      assetStatus: status,
      reservedLocales: await AssetInventory.reservedLocales,
      maximumReservedLocales: AssetInventory.maximumReservedLocales
    )
  }

  /// 実行開始時に記録するアセットの状態
  static func assetStatus(for configuration: EngineConfiguration) async -> String {
    await AssetInventory.status(forModules: [TranscriberModule(configuration).module]).label
  }

  /// アセットのダウンロード要求。不要（導入済み）なら nil
  static func installationRequest(
    for configuration: EngineConfiguration
  ) async throws -> AssetInstallationRequest? {
    try await AssetInventory.assetInstallationRequest(
      supporting: [TranscriberModule(configuration).module]
    )
  }

  static func releaseReservedLocales() async {
    for locale in await AssetInventory.reservedLocales {
      await AssetInventory.release(reservedLocale: locale)
    }
  }

  static func endModelRetention() async {
    await SpeechModels.endRetention()
  }

  static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}

extension SFSpeechRecognizerAuthorizationStatus {
  var label: String {
    switch self {
    case .notDetermined: "notDetermined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .authorized: "authorized"
    @unknown default: "unknown"
    }
  }
}

extension AssetInventory.Status {
  var label: String {
    switch self {
    case .unsupported: "unsupported"
    case .supported: "supported（未ダウンロード）"
    case .downloading: "downloading"
    case .installed: "installed"
    @unknown default: "unknown"
    }
  }
}

/// 1回の認識。結果は `onResult(テキスト, 確定か)` で MainActor に届く。
@MainActor
final class SpeechAnalyzerRun {
  typealias ResultHandler = @MainActor (String, Bool) -> Void

  private let transcriber: TranscriberModule
  private let analyzer: SpeechAnalyzer
  private var resultsTask: Task<Void, any Error>?
  private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

  /// `configuration.locale` は `supportedLocale(equivalentTo:)` で解決済みのものを渡す
  init(configuration: EngineConfiguration) {
    transcriber = TranscriberModule(configuration)
    analyzer = SpeechAnalyzer(
      modules: [transcriber.module],
      options: SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: configuration.retention.value
      )
    )
  }

  /// モデルを読み込み、認識器が受け付ける音声形式を返す
  func prepare() async throws -> AVAudioFormat {
    guard
      let format = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber.module]
      )
    else {
      throw ProbeError.audioFormatUnsupported
    }
    try await analyzer.prepareToAnalyze(in: format)
    return format
  }

  /// マイクなどの逐次入力で解析を始める。返した continuation に入力を流す
  func startStreaming(
    onResult: @escaping ResultHandler
  ) async throws -> AsyncStream<AnalyzerInput>.Continuation {
    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    inputContinuation = continuation
    resultsTask = consumeResults(onResult)
    try await analyzer.start(inputSequence: stream)
    return continuation
  }

  /// 入力を閉じ、残りを確定させて解析を終える。最後の結果が届くまで待つ
  func finishStreaming() async throws {
    inputContinuation?.finish()
    inputContinuation = nil
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    try await resultsTask?.value
  }

  /// 音声ファイルを最後まで解析する。最後の結果が届くまで待つ
  func recognize(file: AVAudioFile, onResult: @escaping ResultHandler) async throws {
    resultsTask = consumeResults(onResult)
    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
    try await resultsTask?.value
  }

  func cancel() async {
    inputContinuation?.finish()
    inputContinuation = nil
    await analyzer.cancelAndFinishNow()
    resultsTask?.cancel()
  }

  private func consumeResults(_ onResult: @escaping ResultHandler) -> Task<Void, any Error> {
    switch transcriber {
    case .speech(let module):
      let results = module.results
      return Task { @MainActor in
        for try await result in results {
          onResult(String(result.text.characters), result.isFinal)
        }
      }
    case .dictation(let module):
      let results = module.results
      return Task { @MainActor in
        for try await result in results {
          onResult(String(result.text.characters), result.isFinal)
        }
      }
    }
  }
}

enum ProbeError: LocalizedError {
  case microphoneDenied
  case microphoneUnavailable
  case audioFormatUnsupported
  case localeUnsupported
  case deviceUnsupported
  case busy

  var errorDescription: String? {
    switch self {
    case .microphoneDenied: "マイクが許可されていません（設定 > プライバシー > マイク）"
    case .microphoneUnavailable: "マイク入力を取得できません"
    case .audioFormatUnsupported: "認識器が受け付ける音声形式を決められません"
    case .localeUnsupported: "この端末・エンジンは ja_JP に対応していません"
    case .deviceUnsupported: "この端末は SpeechTranscriber に対応していません（DictationTranscriber を選ぶ）"
    case .busy: "実行中です"
    }
  }
}
