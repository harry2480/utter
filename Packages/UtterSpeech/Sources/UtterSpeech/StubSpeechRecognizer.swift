import UtterCore

/// 固定のイベント列・遅延・失敗を流すテスト用の音声認識（4章）。
///
/// 音声の中身は使わないが、本番と同じく音声のストリームを最後まで読む。
/// 待ち時間は `sleep` を注入でき、テストでは実時間を待たずに済む。
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
  ///     どちらも含まない場合は、音声のストリームが終わるのを待ってから `completed` を流す
  ///     （値は確定テキストを連結したもの）
  ///   - sleep: 待ち時間の実装。既定は `Task.sleep`。キャンセル以外で失敗したら
  ///     `failed(.engineFailed)` を流して終える
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
    // 終端イベントを落とさないよう、バッファは無制限にする（イベント数は手順の数で決まる）
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    let task = Task {
      var sequence: UInt64 = 0
      var confirmed = ""
      func emit(_ kind: RecognitionEvent.Kind) {
        continuation.yield(RecognitionEvent(sessionID: session, sequence: sequence, kind: kind))
        sequence += 1
      }
      defer { continuation.finish() }
      for step in steps {
        if Task.isCancelled { return }
        switch step {
        case .partial(let text):
          emit(.partial(text))
        case .confirmed(let text):
          confirmed += text
          emit(.confirmed(text))
        case .completed(let text):
          emit(.completed(text))
          return
        case .fail(let error):
          emit(.failed(error))
          return
        case .delay(let duration):
          do {
            try await sleep(duration)
          } catch {
            // 受け手がいなくなった（キャンセル）なら何も流さず、それ以外は失敗として終える
            if !Task.isCancelled {
              emit(.failed(.engineFailed))
            }
            return
          }
        }
      }
      // 録音の終了（音声のストリームの終わり）を待ってから完了する
      for await _ in audio {
        if Task.isCancelled { return }
      }
      if !Task.isCancelled {
        emit(.completed(confirmed))
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }
}

// 認識テキストをログに出さないよう、文字列表現には種類と文字数だけを出す。
extension StubSpeechRecognizer.Step: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .partial(let text): "partial(length: \(text.count))"
    case .confirmed(let text): "confirmed(length: \(text.count))"
    case .completed(let text): "completed(length: \(text.count))"
    case .fail(let error): "fail(\(error))"
    case .delay(let duration): "delay(\(duration))"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
