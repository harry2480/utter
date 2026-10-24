import AVFoundation
import Foundation
import Speech
import Synchronization
import UtterCore

/// `TranscriptionSession` で1回の認識を進め、`SpeechRecognizer` の契約どおりにイベントを流す（4章）。
///
/// - 音声の入力と結果の読み取りを並行して進め、どちらが先に終わったかで終え方を決める
/// - 音声が終わったら `finalize()` で残りを確定させ、確定テキスト全体を `completed` で流す
/// - 失敗したら `failed` を流してから音声の読み取りを止める（録音側が終端イベントで録音の止め方を決められるように）
/// - 受け手がストリームを破棄したら `cancel()` で止め、終端イベントは流さない。モデルのロードや確定の待ちの最中でも止める
enum TranscriptionRun {
  static func events<Session: TranscriptionSession>(
    audio: AsyncStream<AudioChunk>, session id: SessionID,
    makeSession: @escaping @Sendable () async -> Result<Session, SpeechRecognitionError>
  ) -> AsyncStream<RecognitionEvent> {
    // 終端イベントを落とさないよう、バッファは無制限にする（暫定結果は短い文字列で、受け手が読む間だけ溜まる）
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    let emitter = RecognitionEventEmitter(session: id, continuation: continuation)
    let task = Task {
      await run(audio: audio, makeSession: makeSession, emitter: emitter)
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  /// 並行して動く音声の入力と結果の読み取りのうち、どちらが先に終わったか
  private enum Stage: Sendable {
    /// 成功なら渡した音声のバッファの数
    case inputFinished(Result<Int, SpeechRecognitionError>)
    /// 成功なら確定テキスト全体
    case resultsFinished(Result<String, SpeechRecognitionError>)
  }

  private static func run<Session: TranscriptionSession>(
    audio: AsyncStream<AudioChunk>,
    makeSession: @Sendable () async -> Result<Session, SpeechRecognitionError>,
    emitter: RecognitionEventEmitter
  ) async {
    // 受け手がいなくなった（キャンセル）なら終端イベントは流さない
    func finish(_ kind: RecognitionEvent.Kind) {
      if !Task.isCancelled { emitter.emit(kind) }
    }

    let session: Session
    switch await makeSession() {
    case .success(let made): session = made
    case .failure(let error):
      finish(.failed(error))
      return
    }
    do {
      try await cancellingOnTaskCancel(session) { try await session.prepare() }
    } catch {
      finish(.failed(classify(error)))
      await session.cancel()
      return
    }
    if Task.isCancelled {
      await session.cancel()
      return
    }
    let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    do {
      try await session.start(inputs)
    } catch {
      inputContinuation.finish()
      finish(.failed(classify(error)))
      await session.cancel()
      return
    }

    await withTaskGroup(of: Stage.self) { group in
      group.addTask {
        await readResults(session.results(), emitter: emitter)
      }
      group.addTask {
        await feed(audio, format: session.audioFormat, into: inputContinuation)
      }
      guard let first = await group.next() else { return }
      switch first {
      case .inputFinished(.success(let count)):
        // 受け手がいなくなって音声の読み取りが止まった場合も、ここに来る
        if Task.isCancelled {
          group.cancelAll()
          await session.cancel()
          return
        }
        if count == 0 {
          // 音声が1つもなければ解析せずに空の確定テキストで終える（入力なしでの確定の挙動に頼らない）
          finish(.completed(""))
          group.cancelAll()
          await session.cancel()
          return
        }
        do {
          try await cancellingOnTaskCancel(session) { try await session.finalize() }
        } catch {
          finish(.failed(classify(error)))
          group.cancelAll()
          await session.cancel()
          return
        }
        guard case .resultsFinished(let result)? = await group.next() else { return }
        switch result {
        case .success(let text): finish(.completed(text))
        case .failure(let error): finish(.failed(error))
        }

      case .inputFinished(.failure(let error)):
        finish(.failed(error))
        group.cancelAll()
        await session.cancel()

      case .resultsFinished(let result):
        // 音声の終わりより前に結果が終わった（解析器の異常終了、またはキャンセル）
        switch result {
        case .success: finish(.failed(.engineFailed))
        case .failure(let error): finish(.failed(error))
        }
        group.cancelAll()
        await session.cancel()
      }
    }
  }

  /// 時間のかかる呼び出しの最中にタスクがキャンセルされたら、解析器を止めて呼び出しを早く戻す。
  /// 呼び出しがタスクのキャンセルに応じるかに頼らないため。
  private static func cancellingOnTaskCancel<Session: TranscriptionSession>(
    _ session: Session, _ operation: () async throws -> Void
  ) async throws {
    try await withTaskCancellationHandler {
      try await operation()
    } onCancel: {
      Task { await session.cancel() }
    }
  }

  /// 結果を読み、`partial` / `confirmed` を流す。成功なら確定テキスト全体を返す。
  private static func readResults(
    _ results: some AsyncSequence<TranscriptionSegment, any Error>,
    emitter: RecognitionEventEmitter
  ) async -> Stage {
    var mapper = TranscriptionEventMapper()
    do {
      for try await segment in results {
        for kind in mapper.map(segment) {
          emitter.emit(kind)
        }
      }
    } catch is CancellationError {
      // cancelAndFinishNow() の後は CancellationError で終わる場合がある（Probe で確認）。正常な終わりとして扱う
    } catch {
      return .resultsFinished(.failure(classify(error)))
    }
    return .resultsFinished(.success(mapper.confirmedText))
  }

  /// 音声を解析器の形式に変換して渡す。音声が終わったら変換器の残りを渡して入力を閉じる。
  private static func feed(
    _ audio: AsyncStream<AudioChunk>, format: AVAudioFormat,
    into continuation: AsyncStream<AnalyzerInput>.Continuation
  ) async -> Stage {
    defer { continuation.finish() }
    let converter = AudioChunkConverter(outputFormat: format)
    var count = 0
    do {
      for await chunk in audio {
        if let buffer = try converter.convert(chunk) {
          continuation.yield(AnalyzerInput(buffer: buffer))
          count += 1
        }
      }
      if !Task.isCancelled, let rest = try converter.flush() {
        continuation.yield(AnalyzerInput(buffer: rest))
        count += 1
      }
    } catch {
      return .inputFinished(.failure(error))
    }
    return .inputFinished(.success(count))
  }

  /// SpeechAnalyzer のエラーを `SpeechRecognitionError` に分類する。エラーの内容（文言）は使わない。
  static func classify(_ error: any Error) -> SpeechRecognitionError {
    if let error = error as? SpeechRecognitionError { return error }
    let error = error as NSError
    guard error.domain == SFSpeechErrorDomain else { return .engineFailed }
    switch SFSpeechError.Code(rawValue: error.code) {
    case .noModel, .assetLocaleNotAllocated, .tooManyAssetLocalesAllocated,
      .cannotAllocateUnsupportedLocale:
      return .modelUnavailable
    case .unexpectedAudioFormat, .incompatibleAudioFormats:
      return .unsupportedAudioFormat
    case .insufficientResources:
      return .resourceLimited
    default:
      return .engineFailed
    }
  }
}

/// セッションID と順序番号を付けてイベントを流す。結果の読み取りと終端イベントの送信が別のタスクになるため、ロックで守る。
/// 終端イベントは1回だけ流し、その後のイベントは捨てる。
final class RecognitionEventEmitter: Sendable {
  private struct State {
    var sequence: UInt64 = 0
    var finished = false
  }

  private let session: SessionID
  private let continuation: AsyncStream<RecognitionEvent>.Continuation
  private let state = Mutex(State())

  init(session: SessionID, continuation: AsyncStream<RecognitionEvent>.Continuation) {
    self.session = session
    self.continuation = continuation
  }

  /// イベントを流す。終端イベントの後に来たイベント（2回目の終端イベントを含む）は捨てる
  func emit(_ kind: RecognitionEvent.Kind) {
    state.withLock { state in
      guard !state.finished else { return }
      continuation.yield(RecognitionEvent(sessionID: session, sequence: state.sequence, kind: kind))
      state.sequence += 1
      if kind.isTerminal { state.finished = true }
    }
  }
}
