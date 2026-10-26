import UtterCore

/// 権限・機能の表示文言。
extension AppPermission {
  var displayName: String {
    switch self {
    case .microphone: "マイク"
    case .speechRecognition: "音声認識"
    case .accessibility: "アクセシビリティ"
    case .inputMonitoring: "入力監視"
    }
  }
}

extension AppFeature {
  var displayName: String {
    switch self {
    case .recording: "録音と音声認識"
    case .insertion(.accessibility): "入力欄への直接挿入"
    case .insertion(.pasteboard): "貼り付けによる挿入"
    case .insertion(.keyEvents): "キー入力による挿入"
    case .insertion(.textDocumentProxy): "キーボードからの挿入"
    case .modifierOnlyShortcut: "修飾キーだけのショートカット"
    case .escapeCancel: "Esc でのキャンセル"
    }
  }

  /// 表示の順。録音 → 挿入 → ショートカットの、使う流れに沿う
  private var displayOrder: Int {
    switch self {
    case .recording: 0
    case .insertion(let route): 1 + (InsertionRoute.allCases.firstIndex(of: route) ?? 0)
    case .modifierOnlyShortcut: 10
    case .escapeCancel: 11
    }
  }

  /// 機能を表示の順に並べた名前
  static func displayNames(_ features: Set<AppFeature>) -> String {
    features.sorted { $0.displayOrder < $1.displayOrder }.map(\.displayName).joined(separator: "、")
  }
}
