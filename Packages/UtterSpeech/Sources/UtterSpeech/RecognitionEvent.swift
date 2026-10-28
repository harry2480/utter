import UtterCore

/// 音声認識から届くイベント（4章）。
///
/// どのセッションの何番目のイベントかを持ち、受け手はキャンセル済みのセッションや
/// 順序の古いイベントを `RecognitionEventFilter` で破棄する。
public struct RecognitionEvent: Hashable, Sendable, Codable {
  public enum Kind: Hashable, Sendable, Codable {
    /// 暫定の認識結果。後から変わりうる。値は確定済みテキストの後に続く部分で、全体ではない
    case partial(String)
    /// 確定した認識結果の一部。受け手は区切りを足さずに連結するため、必要な空白は値に含める。
    /// 受け手はそれまでの暫定結果を消すため、確定していない部分が残るなら続けて `partial` で送り直す
    case confirmed(String)
    /// 認識の完了。値は全体の確定テキスト。認識器によっては、入力の終わりまでに確定されなかった末尾の暫定結果を
    /// `confirmed` の連結の後に含む（発話の終わりを落とさないため）。受け手は `confirmed` の連結と一致すると仮定しない
    case completed(String)
    /// 認識の失敗
    case failed(SpeechRecognitionError)

    /// セッションの最後のイベントか
    public var isTerminal: Bool {
      switch self {
      case .partial, .confirmed: false
      case .completed, .failed: true
      }
    }
  }

  public let sessionID: SessionID
  /// セッション内の順序番号。0 から1ずつ増える
  public let sequence: UInt64
  public let kind: Kind

  public init(sessionID: SessionID, sequence: UInt64, kind: Kind) {
    self.sessionID = sessionID
    self.sequence = sequence
    self.kind = kind
  }
}

// 認識テキストをログに出さないよう、文字列表現とリフレクションには種類と文字数だけを出す。
extension RecognitionEvent: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "RecognitionEvent(sequence: \(sequence), kind: \(kind))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["sequence": sequence, "kind": kind])
  }
}

extension RecognitionEvent.Kind: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .partial(let text): "partial(length: \(text.count))"
    case .confirmed(let text): "confirmed(length: \(text.count))"
    case .completed(let text): "completed(length: \(text.count))"
    case .failed(let error): "failed(\(error))"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
