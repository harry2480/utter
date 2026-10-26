import Foundation
import UtterCore

/// 権限について覚えておく値（PERM-02）。権限の種類と真偽値だけで、秘密情報・発話は置かない。
@MainActor
final class PermissionDefaults {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Accessibility を一度でも要求したか。要求前の「未確認」と、要求後の「拒否」を分けるために使う
  var hasRequestedAccessibility: Bool {
    get { defaults.bool(forKey: Key.requestedAccessibility) }
    set { defaults.set(newValue, forKey: Key.requestedAccessibility) }
  }

  /// これまでに許可を観測した権限。アプリを再起動しても取り消しを示せるように保存する
  var history: PermissionHistory {
    get {
      let stored = Set(defaults.stringArray(forKey: Key.grantedPermissions) ?? [])
      return PermissionHistory(
        grantedPermissions: Set(AppPermission.allCases.filter { stored.contains($0.storageKey) }))
    }
    set {
      defaults.set(
        AppPermission.allCases.filter(newValue.grantedPermissions.contains).map(\.storageKey),
        forKey: Key.grantedPermissions)
    }
  }

  private enum Key {
    static let requestedAccessibility = "permissions.requestedAccessibility"
    static let grantedPermissions = "permissions.observedGranted"
  }
}

extension AppPermission {
  /// 保存に使う名前。表示文言と分け、変えない
  fileprivate var storageKey: String {
    switch self {
    case .microphone: "microphone"
    case .speechRecognition: "speechRecognition"
    case .accessibility: "accessibility"
    case .inputMonitoring: "inputMonitoring"
    }
  }
}
