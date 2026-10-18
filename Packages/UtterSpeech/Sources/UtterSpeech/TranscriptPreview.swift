/// Realtime Preview に出す、確定済みと暫定の認識テキスト（2.2節, AC-03）。
///
/// `RecognitionEventFilter` が受け付けたイベントだけを `apply(_:)` に渡す。
/// 確定済みテキストは `confirmed` を順に連結したもので、`completed` を受けたら全体の確定テキストに置き換える。
/// 暫定テキストは確定済みテキストの後に続く部分で、新しい `partial` を受けるたびに置き換え、
/// `confirmed` を受けたら消す（確定した部分に吸収されるため）。
///
/// 入力欄への挿入は停止後に一括で行うため、この値は HUD の表示だけに使う。値型なので、
/// 利用側は `@MainActor` や `actor` に隔離して保持する。
public struct TranscriptPreview: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    /// 認識中。`partial` / `confirmed` を受け付ける
    case recognizing
    /// 認識が完了した。確定済みテキストが全体の確定テキスト
    case completed
    /// 認識に失敗した。それまでの確定済みテキストは残す
    case failed(SpeechRecognitionError)
  }

  public private(set) var confirmedText = ""
  public private(set) var provisionalText = ""
  public private(set) var state = State.recognizing

  public init() {}

  /// 受け付けたイベントを反映する。完了・失敗の後に届いたイベントは無視する。
  public mutating func apply(_ kind: RecognitionEvent.Kind) {
    guard state == .recognizing else { return }
    switch kind {
    case .partial(let text):
      provisionalText = text
    case .confirmed(let text):
      confirmedText += text
      provisionalText = ""
    case .completed(let text):
      confirmedText = text
      provisionalText = ""
      state = .completed
    case .failed(let error):
      provisionalText = ""
      state = .failed(error)
    }
  }
}

// 認識テキストをログに出さないよう、文字列表現とリフレクションには状態と文字数だけを出す。
extension TranscriptPreview: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "TranscriptPreview(state: \(state), confirmedLength: \(confirmedText.count), "
      + "provisionalLength: \(provisionalText.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
