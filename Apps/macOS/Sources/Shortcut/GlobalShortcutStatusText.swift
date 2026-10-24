import UtterCore

/// 録音ショートカットの状態をメニューに出す文言（REC-02）。
enum GlobalShortcutStatusText {
  static func text(for status: GlobalShortcutStatus) -> String {
    switch status {
    case .unassigned:
      return "ショートカット: 未設定"
    case .active(let setting):
      return "ショートカット: \(ShortcutNotation.display(setting.combination))（\(modeName(setting.mode))）"
    case .unavailable(let setting, let reason):
      return
        "ショートカット \(ShortcutNotation.display(setting.combination)) を使えません: \(reasonText(reason))"
    }
  }

  static func modeName(_ mode: ShortcutTriggerMode) -> String {
    switch mode {
    case .toggle: "Toggle"
    case .pushToTalk: "Push-to-talk"
    }
  }

  static func reasonText(_ reason: GlobalShortcutUnavailableReason) -> String {
    switch reason {
    case .invalid(let issues):
      // 複数あっても、利用者が最初に直すべき1件だけを出す
      return issues.first.map(issueText) ?? "割り当てられません"
    case .unsupported(let issue):
      switch issue {
      case .modifierOnly: return "修飾キー単独には対応していません"
      case .functionModifier: return "Fn を含む組み合わせには対応していません"
      case .unsupportedKey: return "このキーには対応していません"
      case .missingModifier: return "Command・Option・Control のいずれかと組み合わせてください"
      }
    case .registrationFailed(let failure):
      switch failure {
      case .alreadyRegistered: return "他のアプリが同じ組み合わせを使っています"
      case .handlerUnavailable(let status), .rejected(let status):
        return "登録に失敗しました（OSStatus \(status)）"
      }
    }
  }

  private static func issueText(_ issue: ShortcutValidationIssue) -> String {
    switch issue {
    case .modifierOnlyUnsupported: "修飾キー単独には対応していません"
    case .reservedForCancel: "Esc はキャンセルに使います"
    case .conflict: "システムのショートカットと重なっています"
    }
  }
}
