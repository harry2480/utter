import Foundation
import UtterSpeech
import WhisperKit

/// WhisperKit で推論する `SegmentTranscriber`（4章, PERM-03）。`WhisperKitRecognizer` に渡して使う。
///
/// Phase 0 #49（モデル選定）の判定待ちの先行実装（ライセンスは #47 の D-2 で採用可）。
///
/// ロード（`prepare()`）は通信しないように、次の順で行う（WhisperKitProbe の手順と同じ）。
/// 1. `WhisperKitModelCheck` でモデルのフォルダをマニフェストと照合する。`.ready` でなければロードしない
/// 2. トークナイザーをフォルダから WhisperKit と同じ経路（`AutoTokenizerWrapper.from(modelFolder:)`）で一度読み、
///    読めなければロードしない。WhisperKit はローカルのトークナイザーを読めないと、`download: false` でも
///    Hugging Face から照合なしで取得するため（ライセンス・依存関係.md 3.2）
/// 3. `modelFolder` と `tokenizerFolder` に照合済みのフォルダを指定し、`download: false` で WhisperKit を作ってロードする。
///    トークナイザーを探す場所はすべて照合済みのフォルダの中になる
///
/// 通信しないことは #49 の実機確認で通信を監視して確かめる（推測を含むため）。
///
/// - WhisperKit のログは無効にする（発話本文を出さない）
/// - ロードしたモデルは `unload()` を呼ぶまで保持する。保持・解放の判断は呼び出し側が `ModelRetentionPolicy` で行う
/// - ロードと推論は1つずつ順に行う（WhisperKit のインスタンスを同時に使わない）。順番を待つ間はキャンセルに反応せず、
///   前の処理が終わってから戻る（呼び出し側は結果を使わない）
/// - 照合とトークナイザーの読み込みはファイルを同期的に読む。この actor はメインスレッドの外で動く
public actor WhisperKitTranscriber: SegmentTranscriber {
  public let model: WhisperKitModel
  private var kit: WhisperKit?
  private var isBusy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(model: WhisperKitModel) {
    self.model = model
  }

  /// モデルをロード済みか
  public var isLoaded: Bool {
    kit != nil
  }

  public func prepare() async throws(SpeechRecognitionError) {
    await acquire()
    defer { release() }
    guard kit == nil else { return }
    do {
      kit = try await load()
    } catch {
      throw WhisperKitErrorMapping.recognitionError(for: error, during: .load)
    }
  }

  public func transcribe(_ samples: [Float], language: String) async throws(SpeechRecognitionError)
    -> [TranscribedSegment]
  {
    await acquire()
    defer { release() }
    guard let kit else {
      throw .modelUnavailable
    }
    let results: [TranscriptionResult]
    do {
      results = try await kit.transcribe(
        audioArray: samples, decodeOptions: Self.decodingOptions(language: language))
    } catch {
      throw WhisperKitErrorMapping.recognitionError(for: error, during: .transcribe)
    }
    return Self.segments(from: results.flatMap(\.segments))
  }

  /// ロード済みのモデルを解放する。推論中なら終わるのを待つ。
  /// 認識の途中で呼ぶと、その後の推論は `.modelUnavailable` で失敗する。認識していないときに呼ぶ
  public func unload() async {
    await acquire()
    defer { release() }
    guard let kit else { return }
    self.kit = nil
    await kit.unloadModels()
  }

  private func load() async throws -> WhisperKit {
    let directory = model.directory
    let readiness = try WhisperKitModelCheck(manifest: model.manifest).check(
      LocalModelFileSource(directory: directory))
    if let error = readiness.recognitionError {
      throw error
    }
    // WhisperKit と同じ経路でトークナイザーを読めることを先に確かめる（読めないと WhisperKit が通信して取得するため）
    do {
      _ = try await AutoTokenizerWrapper.from(
        modelFolder: directory, hubApi: HubApiWrapper(downloadBase: directory))
    } catch {
      throw SpeechRecognitionError.modelUnavailable
    }
    let kit = try await WhisperKit(
      WhisperKitConfig(
        modelFolder: directory.path,
        tokenizerFolder: directory,
        // ログに発話本文やパスを出さない
        verbose: false,
        logLevel: .none,
        prewarm: false,
        load: false,
        download: false
      ))
    try await kit.loadModels()
    guard kit.modelState == .loaded, kit.tokenizer != nil else {
      await kit.unloadModels()
      throw SpeechRecognitionError.modelUnavailable
    }
    return kit
  }

  /// 推論の設定。日本語などの言語を指定し、言語判定はしない（WhisperKitProbe と同じ）。
  /// 30秒を超える音声は VAD で分割せず、WhisperKit の通常の処理（30秒ずつ順に進める）に任せる。
  /// VAD で分割すると、分割した一部の推論の失敗を WhisperKit が例外にせず結果から外すため（v1.1.1 の `VADAudioChunker`）、
  /// 発話の一部を黙って失わないよう使わない
  static func decodingOptions(language: String) -> DecodingOptions {
    DecodingOptions(
      verbose: false,
      task: .transcribe,
      language: language,
      usePrefillPrompt: true,
      detectLanguage: false,
      skipSpecialTokens: true,
      chunkingStrategy: ChunkingStrategy.none
    )
  }

  /// WhisperKit の区間を変換する。時刻は推論に渡した音声の先頭からの秒数
  static func segments(from segments: [TranscriptionSegment]) -> [TranscribedSegment] {
    segments.map { segment in
      let end = segment.end.isFinite ? max(0, Double(segment.end)) : 0
      return TranscribedSegment(text: segment.text, end: .seconds(end))
    }
  }

  private func acquire() async {
    guard isBusy else {
      isBusy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if waiters.isEmpty {
      isBusy = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

extension WhisperKitRecognizer where Transcriber == WhisperKitTranscriber {
  /// WhisperKit で認識する。設定が無効（既定）なら認識しない
  public init(model: WhisperKitModel, configuration: WhisperKitRecognizerConfiguration = .disabled)
  {
    self.init(transcriber: WhisperKitTranscriber(model: model), configuration: configuration)
  }
}
