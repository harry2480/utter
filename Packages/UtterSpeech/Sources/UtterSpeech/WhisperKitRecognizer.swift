import Synchronization
import UtterCore

/// WhisperKit で音声を認識する `SpeechRecognizer`（4章）。
///
/// Phase 0 #49（モデル選定）の判定待ちの先行実装（ライセンスは #47 の D-2 で採用可）。設定が無効（既定）なら、
/// 音声を読まずに `failed(.modelUnavailable)` で終える。
///
/// WhisperKit を UtterSpeech の依存に入れないため、推論は `SegmentTranscriber` 越しに行う。
/// 本番の `WhisperKitTranscriber` は UtterSpeechWhisperKit（別の Package）にあり、そちらをリンクしたときだけ WhisperKit を取り込む。
///
/// - 始めに `prepare()` でモデルを使える状態にする。失敗したら音声を読まずに `failed` で終える
/// - 新しい音声が `transcriptionInterval` だけたまるたびに未確定の音声を推論し直し、`confirmed` / `partial` を流す
///   （`WhisperTranscriptAssembler`）。推論の間も音声を読み続け、次の推論でまとめて扱う。
///   推論中に録音が終わったら、途中の推論をせずに最後の推論に進む
/// - 音声が終わったら、未確定の音声を推論して `completed` を流す
/// - サンプリング周波数が `WhisperKitRecognizerConfiguration.sampleRate` でないチャンクが届いたら
///   `failed(.unsupportedAudioFormat)` で終える（変換は録音側の責務）
/// - 受け手がストリームを破棄したら、推論の結果を待たずにイベントを流すのをやめる。
///   推論そのものを途中で止められるかはエンジン次第（`SegmentTranscriber.transcribe`）
public struct WhisperKitRecognizer<Transcriber: SegmentTranscriber>: SpeechRecognizer {
  public let transcriber: Transcriber
  public let configuration: WhisperKitRecognizerConfiguration

  public init(transcriber: Transcriber, configuration: WhisperKitRecognizerConfiguration) {
    self.transcriber = transcriber
    self.configuration = configuration
  }

  public func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent> {
    let transcriber = transcriber
    let configuration = configuration
    // 終端イベントを落とさないよう、バッファは無制限にする（イベント数は推論の回数で決まる）
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    let task = Task {
      var sequence: UInt64 = 0
      func emit(_ kind: RecognitionEvent.Kind) {
        continuation.yield(RecognitionEvent(sessionID: session, sequence: sequence, kind: kind))
        sequence += 1
      }
      defer { continuation.finish() }
      guard configuration.isEnabled else {
        emit(.failed(.modelUnavailable))
        return
      }
      do throws(SpeechRecognitionError) {
        // 準備に失敗したら音声を読まずに終える（読んだ音声を失わないよう、準備の後に読み始める）
        try await transcriber.prepare()
        if Task.isCancelled { return }
        // 推論の間も音声を読み続け、推論のたびにそれまでに届いた分をまとめて渡す。
        // 推論が録音より遅くても、たまった音声を1回の推論で扱い、遅れが積み重ならないようにする
        let inbox = AudioInbox()
        let (arrivals, arrival) = AsyncStream.makeStream(
          of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let reader = Task {
          for await chunk in audio {
            inbox.append(chunk)
            arrival.yield()
          }
          inbox.finish()
          arrival.finish()
        }
        // 終端イベントの後（失敗・キャンセルを含む）は音声を読まない
        defer { reader.cancel() }
        var assembler = WhisperTranscriptAssembler(configuration: configuration)
        for await _ in arrivals {
          if Task.isCancelled { return }
          let received = inbox.take()
          var isDue = false
          for chunk in received.chunks where try assembler.append(chunk) {
            isDue = true
          }
          // 録音が終わっていれば、途中の推論を飛ばして最後の推論に進む
          if received.isFinished { break }
          guard isDue else { continue }
          let segments = try await transcriber.transcribe(
            assembler.pendingSamples, language: configuration.language)
          if Task.isCancelled { return }
          for kind in assembler.applyIntermediate(segments) {
            emit(kind)
          }
        }
        if Task.isCancelled { return }
        for chunk in inbox.take().chunks {
          _ = try assembler.append(chunk)
        }
        let tail =
          assembler.hasPendingAudio
          ? try await transcriber.transcribe(
            assembler.pendingSamples, language: configuration.language)
          : []
        if Task.isCancelled { return }
        emit(assembler.complete(tail))
      } catch {
        // 受け手がいなくなった（キャンセル）なら何も流さない
        if !Task.isCancelled {
          emit(.failed(error))
        }
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }
}

/// 読み込み用のタスクが受け取った音声を、推論するタスクに渡す入れ物
private final class AudioInbox: Sendable {
  private struct State {
    var chunks: [AudioChunk] = []
    var isFinished = false
  }

  private let state = Mutex(State())

  func append(_ chunk: AudioChunk) {
    state.withLock { $0.chunks.append(chunk) }
  }

  func finish() {
    state.withLock { $0.isFinished = true }
  }

  /// 受け取った音声を取り出す。録音が終わっていれば `isFinished` が `true`（取り出した音声が最後）
  func take() -> (chunks: [AudioChunk], isFinished: Bool) {
    state.withLock { state in
      defer { state.chunks = [] }
      return (state.chunks, state.isFinished)
    }
  }
}
