import Foundation
import Testing
import UtterCore
import UtterSpeech
import WhisperKit

@testable import UtterSpeechWhisperKit

// モデルを使わない部分（失敗の分類・結果の変換・推論の設定・ロード前の検証の分岐）を確かめる。
// 実際のモデルでのロード・推論と、通信しないことの確認は #49 の実機確認で行う。
struct WhisperKitTranscriberTests {
  static let digest = String(repeating: "d", count: 64)

  static func manifest(_ paths: [String]) throws -> ModelManifest {
    try ModelManifest(
      files: paths.map { try ModelManifest.File(path: $0, byteCount: 1, sha256: digest) })
  }

  static let completePaths = [
    "MelSpectrogram.mlmodelc/coremldata.bin",
    "AudioEncoder.mlmodelc/coremldata.bin",
    "TextDecoder.mlmodelc/coremldata.bin",
    "tokenizer.json",
    "tokenizer_config.json",
  ]

  /// 存在しないモデルのディレクトリ
  static func missingDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "utter-whisperkit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  @Test(
    "REC-06: モデル・トークナイザー・初期化の失敗はモデルを使えない扱いにする",
    arguments: [
      WhisperError.tokenizerUnavailable(), .modelsUnavailable(), .initializationError(),
    ])
  func mapsModelErrors(_ error: WhisperError) {
    #expect(WhisperKitErrorMapping.recognitionError(for: error, during: .load) == .modelUnavailable)
    #expect(
      WhisperKitErrorMapping.recognitionError(for: error, during: .transcribe) == .modelUnavailable)
  }

  @Test(
    "REC-06: 推論中のそれ以外の失敗はエンジンの異常、ロード中はモデルを使えない扱いにする",
    arguments: [
      WhisperError.audioProcessingFailed(), .decodingLogitsFailed(), .segmentingFailed(),
      .transcriptionFailed(), .decodingFailed(), .prepareDecoderInputsFailed(),
    ])
  func mapsEngineErrors(_ error: WhisperError) {
    #expect(
      WhisperKitErrorMapping.recognitionError(for: error, during: .transcribe) == .engineFailed)
    #expect(WhisperKitErrorMapping.recognitionError(for: error, during: .load) == .modelUnavailable)
  }

  @Test("REC-06: 分類済みの失敗はそのまま返し、WhisperKit 以外の失敗も段階で分ける")
  func mapsOtherErrors() {
    #expect(
      WhisperKitErrorMapping.recognitionError(
        for: SpeechRecognitionError.resourceLimited, during: .transcribe) == .resourceLimited)
    #expect(
      WhisperKitErrorMapping.recognitionError(for: CocoaError(.fileReadCorruptFile), during: .load)
        == .modelUnavailable)
    #expect(
      WhisperKitErrorMapping.recognitionError(
        for: CocoaError(.fileReadCorruptFile), during: .transcribe) == .engineFailed)
  }

  @Test("REC-06: WhisperKit の区間をテキストと終わりの時刻に変換する")
  func convertsSegments() {
    let segments = WhisperKitTranscriber.segments(from: [
      TranscriptionSegment(start: 0, end: 1.5, text: " 明日は"),
      TranscriptionSegment(start: 1.5, end: -1, text: "晴れ"),
      TranscriptionSegment(start: 2, end: .nan, text: "です"),
    ])

    #expect(
      segments == [
        TranscribedSegment(text: " 明日は", end: .seconds(1.5)),
        TranscribedSegment(text: "晴れ", end: .zero),
        TranscribedSegment(text: "です", end: .zero),
      ])
  }

  @Test("REC-06: 推論は指定した言語で行い、言語判定・特殊トークンの出力・VAD での分割をしない")
  func decodingOptionsUseLanguage() {
    let options = WhisperKitTranscriber.decodingOptions(language: "ja")

    #expect(options.language == "ja")
    #expect(!options.detectLanguage)
    #expect(options.skipSpecialTokens)
    #expect(!options.verbose)
    #expect(options.task == .transcribe)
    #expect(options.chunkingStrategy == ChunkingStrategy.none)
  }

  @Test("PERM-03: モデルのフォルダがなければロードせず、モデルを使えない扱いにする")
  func prepareFailsWithoutModel() async throws {
    let transcriber = WhisperKitTranscriber(
      model: WhisperKitModel(
        directory: Self.missingDirectory(), manifest: try Self.manifest(Self.completePaths)))

    await #expect(throws: SpeechRecognitionError.modelUnavailable) {
      try await transcriber.prepare()
    }
    #expect(await !transcriber.isLoaded)
  }

  @Test("PERM-03: マニフェストにロードに要るファイルがなければロードしない")
  func prepareFailsWithIncompleteManifest() async throws {
    let transcriber = WhisperKitTranscriber(
      model: WhisperKitModel(
        directory: Self.missingDirectory(),
        manifest: try Self.manifest(["tokenizer.json"])))

    await #expect(throws: SpeechRecognitionError.modelUnavailable) {
      try await transcriber.prepare()
    }
  }

  @Test("REC-06: ロードする前の推論はモデルを使えない扱いにする")
  func transcribeBeforePrepareFails() async throws {
    let transcriber = WhisperKitTranscriber(
      model: WhisperKitModel(
        directory: Self.missingDirectory(),
        manifest: try Self.manifest(Self.completePaths)))

    await #expect(throws: SpeechRecognitionError.modelUnavailable) {
      try await transcriber.transcribe([0, 0, 0], language: "ja")
    }
  }

  @Test("REC-06: 既定の設定（無効）で作った認識は、モデルをロードせずに失敗で終える")
  func recognizerIsDisabledByDefault() async throws {
    let recognizer = WhisperKitRecognizer(
      model: WhisperKitModel(
        directory: Self.missingDirectory(),
        manifest: try Self.manifest(Self.completePaths)))
    let audio = AsyncStream<UtterSpeech.AudioChunk> { $0.finish() }

    var kinds: [RecognitionEvent.Kind] = []
    for await event in recognizer.recognize(audio, session: SessionID()) {
      kinds.append(event.kind)
    }

    #expect(!recognizer.configuration.isEnabled)
    #expect(kinds == [.failed(.modelUnavailable)])
    #expect(await !recognizer.transcriber.isLoaded)
  }
}
