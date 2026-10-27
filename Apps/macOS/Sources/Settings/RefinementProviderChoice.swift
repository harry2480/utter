import UtterPersistence

/// 設定画面で選ぶ整形の処理系（AI-01, AI-03, AC-05）。保存は `AppSettings.refinementEngine` と
/// `AppSettings.cloudRefinementProvider` で行う。
///
/// ChatGPT は2つの方式を別の選択肢として並べ、黙って切り替えない（#50 の判定の条件, S7）。
/// Sign in with ChatGPT（利用者の ChatGPT プラン）は選べる。OpenAI API キー方式は整形の送信先としては
/// まだアプリから組み立てていないため、選択肢として見せるが選べない。
enum RefinementProviderChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
  /// ローカルのルールベース整形（オフライン, AI-03）
  case localBasic
  /// Claude API による整形（AI-01）。送信には同意が要る（AC-06）
  case claude
  /// Sign in with ChatGPT による整形（AI-01, AI-02, #50）。送信には同意とサインインが要る（AC-06）
  case chatGPTSignIn
  /// OpenAI API キー方式による整形（11章の代替）。整形の送信先としては準備中で選べない
  case openAIAPIKey

  var id: Self { self }

  /// 保存済みの処理系と送信先から選択肢を作る
  init(engine: RefinementEngine, cloudProvider: CloudRefinementProvider) {
    switch (engine, cloudProvider) {
    case (.localBasic, _): self = .localBasic
    case (.cloudAI, .claude): self = .claude
    case (.cloudAI, .chatGPTSignIn): self = .chatGPTSignIn
    }
  }

  /// 選べるか。選べない選択肢は保存しない
  var isSelectable: Bool {
    engine != nil
  }

  /// 保存する処理系。選べない選択肢は `nil`
  var engine: RefinementEngine? {
    switch self {
    case .localBasic: .localBasic
    case .claude, .chatGPTSignIn: .cloudAI
    case .openAIAPIKey: nil
    }
  }

  /// 保存するクラウド整形の送信先。Local Basic・選べない選択肢は `nil`（保存済みの送信先を変えない）
  var cloudProvider: CloudRefinementProvider? {
    switch self {
    case .claude: .claude
    case .chatGPTSignIn: .chatGPTSignIn
    case .localBasic, .openAIAPIKey: nil
    }
  }
}
