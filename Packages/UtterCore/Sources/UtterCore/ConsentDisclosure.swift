/// 同意の画面で、同意対象ごとに示す説明（AC-06, AI-04, CTX-03, 7章）。
///
/// 何を・どこへ送るか、送らないものを、同意対象だけから組み立てる。
/// 発話本文・入力欄の内容・ウィンドウタイトル・URL などの利用者のデータを受け取らないため、説明にそれらが入ることはない。
public struct ConsentDisclosure: Hashable, Sendable {
  /// 同意対象の見出し
  public let title: String
  /// 送る内容
  public let content: String
  /// 送信先
  public let destination: String
  /// 送らないもの（CTX-03）
  public let notSent: [String]
  /// 補足（送る条件など）
  public let note: String?

  /// クラウド AI へ送らない文脈（CTX-03）。スタイル区分と辞書語以外の文脈は送らない
  public static let contextNotSent = ["ウィンドウタイトル", "入力欄の既存本文", "URL"]

  public init(scope: ConsentScope) {
    switch scope {
    case .transmission(.textRefinement(let provider)):
      title = "\(Self.name(of: provider)) による文章整形"
      content = "音声認識したテキストと、整形のモード・スタイル区分・辞書語"
      destination = Self.destination(of: provider)
      notSent = ["音声"] + Self.contextNotSent
      note = "Raw モードと Local Basic では送信しません。"
    case .transmission(.speechRecognition):
      title = "クラウド音声認識"
      content = "録音した音声"
      // 送信先は OpenAI の音声認識 API だけ（#188。ほかのクラウド STT は持たない）
      destination = "OpenAI（音声認識 API）"
      notSent = ["辞書語"] + Self.contextNotSent
      note = "文章整形・選択テキストの編集への同意とは別の同意です。設定画面でクラウド音声認識を選んだときだけ送信します。"
    case .transmission(.editSelection(let provider)):
      title = "\(Self.name(of: provider)) による選択テキストの編集"
      content = "選択したテキストと、音声による編集の指示・辞書語"
      destination = Self.destination(of: provider)
      notSent = ["音声"] + Self.contextNotSent
      note = "音声入力の整形への同意とは別の同意です。"
    case .crossProviderFallback:
      title = "別のクラウド AI への自動切り替え"
      content = "整形に失敗したときに、同じテキストを別のクラウド AI へ送り直すこと"
      destination = "整形の送信に同意しているもう一方のクラウド AI"
      notSent = ["音声"] + Self.contextNotSent
      note = "切り替え元と切り替え先の両方の文章整形に同意している場合に限ります。"
    }
  }

  private static func name(of provider: CloudAIProviderKind) -> String {
    switch provider {
    case .claude: "Claude"
    case .chatGPT: "ChatGPT"
    }
  }

  private static func destination(of provider: CloudAIProviderKind) -> String {
    switch provider {
    case .claude: "Anthropic（Claude API）"
    case .chatGPT: "OpenAI"
    }
  }
}
