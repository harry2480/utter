/// キーボード拡張で提示する操作と案内（iOS-08, iOS-09, iAC-05〜07）。
///
/// 制限のある入力欄（セキュア入力欄・電話番号欄・判定できない欄）では、通常の文字入力とキーボードの切り替えだけを残し、
/// 共有結果の表示・挿入と本体アプリへの移動を提示しない。標準キーボードへの切り替えを案内し、制約を回避する手段は作らない。
///
/// 呼び出し側の契約: 共有結果は `actions` が `sharedResult` を含むときだけ読み込む。挿入の直前にもその時点の入力欄で
/// 判定し直し、含まなくなったら挿入しない。
public struct KeyboardAvailability: Hashable, Sendable {
  /// 提示する操作
  public let actions: Set<KeyboardAction>
  /// 何ができないか・どうすれば直るかの案内。優先して見せる順
  public let notices: [KeyboardNotice]

  public init(_ environment: KeyboardEnvironment) {
    let restrictions = Self.restrictions(of: environment.inputField)
    guard restrictions.isEmpty else {
      actions = [.typing]
      notices = [.restrictedInputField(restrictions)]
      return
    }

    var actions: Set<KeyboardAction> = [.typing, .openHostApp]
    var notices: [KeyboardNotice] = []
    if environment.canAccessSharedContainer {
      actions.insert(.sharedResult)
    } else if environment.hasFullAccess {
      // フルアクセスがあっても読めないなら、App Group の Entitlement・署名の不備
      notices.append(.sharedContainerUnavailable)
    } else {
      notices.append(.fullAccessRequired)
    }
    if let hostApp = environment.hostApp {
      notices += Self.notices(for: hostApp)
    }
    self.actions = actions
    self.notices = notices
  }

  private static func restrictions(of field: KeyboardInputField) -> Set<KeyboardFieldRestriction> {
    var restrictions: Set<KeyboardFieldRestriction> = []
    switch field.secureTextEntry {
    case .on: restrictions.insert(.secureTextEntry)
    case .unknown: restrictions.insert(.undetermined)
    case .off: break
    }
    switch field.phoneNumber {
    case .on: restrictions.insert(.phoneNumber)
    case .unknown: restrictions.insert(.undetermined)
    case .off: break
    }
    return restrictions
  }

  private static func notices(for hostApp: HostAppStatus) -> [KeyboardNotice] {
    var notices: [KeyboardNotice] = HostAppPermission.allCases
      .filter(hostApp.deniedPermissions.contains)
      .map(KeyboardNotice.permissionDenied)
    switch (hostApp.speechModel, hostApp.network) {
    case (.notDownloaded, .online): notices.append(.speechModelNotDownloaded)
    case (.notDownloaded, .offline): notices.append(.speechModelNotDownloadedOffline)
    case (.ready, _): break
    }
    if hostApp.usesCloudRefinement, hostApp.network == .offline {
      notices.append(.cloudRefinementOffline)
    }
    return notices
  }
}

/// キーボードで提示する操作。
public enum KeyboardAction: Hashable, Sendable {
  /// 通常の文字入力・削除・改行・キーボードの切り替え（iOS-08）。常に提示する
  case typing
  /// 共有結果の表示と、明示的な挿入（iOS-05）
  case sharedResult
  /// 録音のための本体アプリへの移動（iOS-03, iAC-05）
  case openHostApp
}

/// 共有結果の挿入と本体アプリへの移動を提示しない入力欄の理由（iOS-09, iAC-06）。
public enum KeyboardFieldRestriction: Hashable, Sendable {
  case secureTextEntry
  case phoneNumber
  /// 入力欄の属性が取れない（安全側に倒す）
  case undetermined
}

/// キーボードに表示する案内（iAC-06, iAC-07）。
public enum KeyboardNotice: Hashable, Sendable {
  /// 制限のある入力欄。標準キーボードで入力する
  case restrictedInputField(Set<KeyboardFieldRestriction>)
  /// フルアクセスが無効で共有結果を読めない
  case fullAccessRequired
  /// フルアクセスがあっても共有結果を読めない（App Group の Entitlement・署名の不備）
  case sharedContainerUnavailable
  /// 本体アプリの権限が拒否され、録音・認識できない
  case permissionDenied(HostAppPermission)
  /// STT モデルが未取得で、認識できない
  case speechModelNotDownloaded
  /// STT モデルが未取得で、オフラインのため取得もできない
  case speechModelNotDownloadedOffline
  /// オフラインのため、クラウド AI で整形できずローカルで整形する（AC-16）
  case cloudRefinementOffline

  /// 利用者が取れる対処
  public var remedy: KeyboardRemedy {
    switch self {
    case .restrictedInputField: .switchToSystemKeyboard
    case .fullAccessRequired: .enableFullAccess
    case .sharedContainerUnavailable: .reinstallWithValidSigning
    case .permissionDenied(let permission): .allowPermission(permission)
    case .speechModelNotDownloaded: .downloadSpeechModel
    case .speechModelNotDownloadedOffline, .cloudRefinementOffline: .connectToNetwork
    }
  }
}

/// 案内に添える対処。
public enum KeyboardRemedy: Hashable, Sendable {
  /// 地球儀キーで標準キーボードへ切り替える
  case switchToSystemKeyboard
  /// 設定アプリでキーボードのフルアクセスを許可する
  case enableFullAccess
  /// 本体アプリとキーボードを App Group を含む正しい署名で入れ直す
  case reinstallWithValidSigning
  /// 設定アプリで本体アプリに権限を許可する
  case allowPermission(HostAppPermission)
  /// 本体アプリで STT モデルを取得する
  case downloadSpeechModel
  /// ネットワークに接続する
  case connectToNetwork
}
