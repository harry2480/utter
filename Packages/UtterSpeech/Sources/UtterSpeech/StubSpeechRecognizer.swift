import UtterCore

/// 固定のイベント列・遅延・失敗を流すテスト用の音声認識（4章）。
///
/// 音声の中身は使わない。待ち時間は `sleep` を注入でき、テストでは実時間を待たずに済む。
public struct StubSpeechRecognizer: SpeechRecognizer {
  public enum Step: Hashable, Sendable {
    case partial(String)
    case confirmed(String)
    case completed(String)
    case fail(SpeechRecognitionError)
    /// 次のイベントまで待つ
    case delay(Duration)
  }

  public let steps: [Step]
  private let sleep: @Sendable (Duration) async throws -> Void

  /// - Parameters:
  ///   - steps: 流すイベントと待ち時間。`completed` か `fail` の後の手順は流さない。
  ///     どちらも含まない場合は、最後に `completed` を流す（値は確定テキストを連結したもの）
  ///   - sleep: 待ち時間の実装。既定は `Task.sleep`。エラーを投げたら完了を流さずに終える
  public init(
    steps: [Step],
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.steps = steps
    self.sleep = sleep
  }

  public func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent> {
    let steps = steps
    let sleep = sleep
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    let task = Task {
      var sequence: UInt64 = 0
      var confirmed = ""
      func emit(_ kind: RecognitionEvent.Kind) {
        continuation.yield(RecognitionEvent(sessionID: session, sequence: sequence, kind: kind))
        sequence += 1
      }
      for step in steps {
        if Task.isCancelled { break }
        switch step {
        case .partial(let text):
          emit(.partial(text))
        case .confirmed(let text):
          confirmed += text
          emit(.confirmed(text))
        case .completed(let text):
          emit(.completed(text))
          continuation.finish()
          return
        case .fail(let error):
          emit(.failed(error))
          continuation.finish()
          return
        case .delay(let duration):
          do {
            try await sleep(duration)
          } catch {
            // キャンセルされた（または sleep が失敗した）ら、完了を流さずに終える
            continuation.finish()
            return
          }
        }
      }
      if !Task.isCancelled {
        emit(.completed(confirmed))
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }
}
