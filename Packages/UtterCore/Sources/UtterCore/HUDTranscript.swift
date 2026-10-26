/// HUD の Realtime Preview に出す認識テキスト（2.2節, AC-03）。
///
/// 確定済みのテキストと、その後に続く暫定のテキストを分けて持ち、画面は両者を区別して描画する。
/// 入力モードが Realtime Preview のときだけ、セッションを進める側（UtterSpeech の `TranscriptPreview` を持つ側）が作って
/// `HUDController.updateTranscript(_:for:)` に渡す。HUD の中で発話本文を持つのはこの値だけで、
/// VoiceOver の読み上げ（`HUDPresentation.accessibilityLabel` / `announcement`）・ログ・`description` には出さない。
public struct HUDTranscript: Hashable, Sendable {
  public let confirmedText: String
  public let provisionalText: String

  public init(confirmedText: String, provisionalText: String) {
    self.confirmedText = confirmedText
    self.provisionalText = provisionalText
  }

  /// 表示する文字がない
  public var isEmpty: Bool {
    confirmedText.isEmpty && provisionalText.isEmpty
  }
}

// 認識テキストをログに出さないよう、文字列表現とリフレクションには文字数だけを出す。
extension HUDTranscript: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "HUDTranscript(confirmedLength: \(confirmedText.count), "
      + "provisionalLength: \(provisionalText.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
