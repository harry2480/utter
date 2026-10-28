import UtterPersistence

/// 設定画面で選ぶ整形の処理系（AI-01, AI-03, AC-05）。保存は `AppSettings.refinementEngine` と
/// `AppSettings.cloudRefinementProvider` で行う。
///
/// ChatGPT は2つの方式を別の選択肢として並べ、黙って切り替えない（#50 の判定の条件, S7）。
/// Sign in with ChatGPT（利用者の ChatGPT プラン）と OpenAI API キー方式（利用者の API キー。トークン課金, #58）は
/// どちらも OpenAI へ送るため、送信の同意は同じ送信先（ChatGPT）として扱う。
enum RefinementProviderChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
  /// ローカルのルールベース整形（オフライン, AI-03）
  case localBasic
  /// Claude API による整形（AI-01）。送信には同意が要る（AC-06）
  case claude
  /// Sign in with ChatGPT による整形（AI-01, AI-02, #50）。送信には同意とサインインが要る（AC-06）
  case chatGPTSignIn
  /// OpenAI API キー方式による整形（AI-01, #58）。送信には同意・OpenAI API キー・予算・モデル名が要る（AC-06, AI-04）
  case openAIAPIKey

  var id: Self { self }

  /// 保存済みの処理系と送信先から選択肢を作る
  init(engine: RefinementEngine, cloudProvider: CloudRefinementProvider) {
    switch (engine, cloudProvider) {
    case (.localBasic, _): self = .localBasic
    case (.cloudAI, .claude): self = .claude
    case (.cloudAI, .chatGPTSignIn): self = .chatGPTSignIn
    case (.cloudAI, .openAIAPIKey): self = .openAIAPIKey
    }
  }

  /// 保存する処理系
  var engine: RefinementEngine {
    switch self {
    case .localBasic: .localBasic
    case .claude, .chatGPTSignIn, .openAIAPIKey: .cloudAI
    }
  }

  /// 保存するクラウド整形の送信先。Local Basic は `nil`（保存済みの送信先を変えない）
  var cloudProvider: CloudRefinementProvider? {
    switch self {
    case .claude: .claude
    case .chatGPTSignIn: .chatGPTSignIn
    case .openAIAPIKey: .openAIAPIKey
    case .localBasic: nil
    }
  }
}
