import UtterPersistence

/// 設定画面で選ぶ整形の処理系（AI-03, AC-05）。保存は `AppSettings.refinementEngine` で行う。
///
/// クラウド AI の送信先は、現時点では Claude API だけ。ChatGPT は Phase 0 #50 の判定待ちで接続の実装がないため、
/// 選択肢として見せるが選べない。判定後に ChatGPT を選べるようにするときは、送信先を保存する項目を `AppSettings` に足す。
enum RefinementProviderChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
  /// ローカルのルールベース整形（オフライン, AI-03）
  case localBasic
  /// Claude API による整形（AI-01）。送信には同意が要る（AC-06）
  case claude
  /// ChatGPT による整形（AI-01, AI-02）。Phase 0 #50 の判定待ちで選べない
  case chatGPT

  var id: Self { self }

  /// 保存済みの処理系から選択肢を作る。クラウド AI は現時点では Claude だけを指す
  init(engine: RefinementEngine) {
    switch engine {
    case .localBasic: self = .localBasic
    case .cloudAI: self = .claude
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
    case .claude: .cloudAI
    case .chatGPT: nil
    }
  }
}
