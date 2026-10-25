import UtterCore

extension SpeechRecognizer {
  /// 録音済みの音声で認識をやり直す（7章, AC-10）。
  ///
  /// STT Worker の異常終了後はメモリ上の `RecordedAudio` を、アプリの異常終了後は一時音声から戻した
  /// `RecordedAudio` を渡す。一時音声と状態機械が同じセッションを指すよう、`session` には元のセッションID を
  /// そのまま渡す。認識の順序番号は 0 から始まり直すため、受け付けるイベントは同じ `SessionID` で
  /// `RecognitionEventFilter.begin(_:)` を呼んで初期化したフィルターで判定する。
  ///
  /// キャンセルされたら認識のストリームを破棄して認識を止め、`cancelled` を返す。
  public func recognizeAgain(
    _ audio: RecordedAudio, session: SessionID,
    chunkDuration: Duration = .milliseconds(100)
  ) async -> RecordedAudioRecognitionResult {
    var filter = RecognitionEventFilter()
    filter.begin(session)
    for await event in recognize(audio.stream(chunkDuration: chunkDuration), session: session) {
      if Task.isCancelled { return .cancelled }
      guard filter.accept(event) == nil else { continue }
      switch event.kind {
      case .completed(let text): return .completed(text)
      case .failed(let error): return .failed(error)
      case .partial, .confirmed: continue
      }
    }
    // 終端イベントなしに終わるのは、キャンセルされたときか、実装が契約を守らずに止まったとき
    return Task.isCancelled ? .cancelled : .failed(.engineFailed)
  }
}

/// 録音済みの音声で認識をやり直した結果（7章, AC-10）
public enum RecordedAudioRecognitionResult: Hashable, Sendable {
  /// 認識を終えた。値は全体の確定テキスト
  case completed(String)
  case failed(SpeechRecognitionError)
  case cancelled
}

// 認識テキストをログに出さないよう、文字列表現とリフレクションには種類と文字数だけを出す。
extension RecordedAudioRecognitionResult: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .completed(let text): "completed(length: \(text.count))"
    case .failed(let error): "failed(\(error))"
    case .cancelled: "cancelled"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
