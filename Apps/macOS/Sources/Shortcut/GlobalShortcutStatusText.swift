import UtterCore

/// 録音ショートカットの状態をメニューに出す文言（REC-01, REC-02, PERM-02）。
enum GlobalShortcutStatusText {
  static func text(for status: GlobalShortcutStatus) -> String {
    switch status {
    case .unassigned:
      return "ショートカット: 未設定"
    case .active(let setting):
      return "ショートカット: \(ShortcutNotation.display(setting))（\(modeName(setting.mode))）"
    case .unavailable(let setting, let reason):
      return "ショートカット \(ShortcutNotation.display(setting)) を使えません: \(reasonText(reason))"
    }
  }

  /// Esc 捕捉の状態。使わないとき（`.off`）は表示しない。
  static func text(for status: EscapeCaptureStatus) -> String? {
    switch status {
    case .off:
      return nil
    case .ready:
      return "Esc でキャンセル: 録音〜整形中に使えます"
    case .unavailable(.permissionMissing(let permission)):
      return "Esc でキャンセル: \(permissionName(permission))の許可がないため使えません"
    case .unavailable(.tapCreationFailed):
      return "Esc でキャンセル: キー入力の捕捉を開始できません"
    }
  }

  static func modeName(_ mode: ShortcutTriggerMode) -> String {
    switch mode {
    case .toggle: "Toggle"
    case .pushToTalk: "Push-to-talk"
    }
  }

  static func permissionName(_ permission: EventTapPermission) -> String {
    switch permission {
    case .inputMonitoring: "入力監視"
    case .accessibility: "アクセシビリティ"
    }
  }

  /// 権限を求めるメニュー項目の文言（PERM-01。用途を添える）。
  static func requestTitle(for permission: EventTapPermission) -> String {
    switch permission {
    case .inputMonitoring: "修飾キー単独のショートカットのため、入力監視を許可…"
    case .accessibility: "Esc でキャンセルするため、アクセシビリティを許可…"
    }
  }

  static func reasonText(_ reason: GlobalShortcutUnavailableReason) -> String {
    switch reason {
    case .invalid(let issues):
      // 複数あっても、利用者が最初に直すべき1件だけを出す
      return issues.first.map(issueText) ?? "割り当てられません"
    case .unsupported(let issue):
      switch issue {
      case .modifierOnly: return "修飾キー単独は Fn か、左右を指定した1つの修飾キーだけに対応しています"
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
    case .eventTapUnavailable(.permissionMissing(let permission)):
      return "\(permissionName(permission))の許可がありません。許可するか、通常のキー組み合わせを割り当ててください"
    case .eventTapUnavailable(.tapCreationFailed):
      return "キー入力の監視を開始できません。utter を再起動するか、通常のキー組み合わせを割り当ててください"
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
