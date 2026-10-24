/// キーボード拡張が表示時に観測できる状態（iOS-09, iAC-06, iAC-07）。拡張側が OS の状態から作る。
///
/// キーボード禁止アプリでは OS が拡張を起動しないため、ここには現れない。拡張から検出・回避する手段は作らない。
public struct KeyboardEnvironment: Hashable, Sendable {
  /// 「フルアクセスを許可」が有効か（`UIInputViewController.hasFullAccess`）
  public var hasFullAccess: Bool
  /// App Group の共有コンテナの状態
  public var sharedContainer: SharedContainerState
  /// 現在の入力欄
  public var inputField: KeyboardInputField
  /// 拡張が観測したネットワークの状態。本体アプリが残した値は古くなりやすいため、拡張側で観測する
  public var network: NetworkReachability

  public init(
    hasFullAccess: Bool,
    sharedContainer: SharedContainerState,
    inputField: KeyboardInputField,
    network: NetworkReachability
  ) {
    self.hasFullAccess = hasFullAccess
    self.sharedContainer = sharedContainer
    self.inputField = inputField
    self.network = network
  }
}

/// App Group の共有コンテナの状態。本体アプリの状態は共有コンテナから読むため、読めるときだけ持つ。
public enum SharedContainerState: Hashable, Sendable {
  /// このビルドでは App Group を設定していない（App Group ID が空）。共有結果を読まない
  case notConfigured
  /// 読めない。共有結果を表示・挿入できず、本体アプリの状態も分からない
  case unavailable
  /// 読める。本体アプリが状態を残していなければ `hostApp` は `nil`
  case available(hostApp: HostAppStatus?)
}

/// キーボードが表示されている入力欄の種類（iOS-09, iAC-06）。拡張側が入力欄の属性
/// （`UITextDocumentProxy` の `isSecureTextEntry` / `keyboardType`）から作る。
///
/// これらの入力欄では通常 OS が標準キーボードへ切り替えるため、拡張に届くのは OS の判定をすり抜けた場合だけ。
/// 取得できない属性は `unknown` にする。
public struct KeyboardInputField: Hashable, Sendable {
  /// セキュア入力欄（パスワード欄など）か
  public var secureTextEntry: SensitiveSignal
  /// 電話番号の入力欄（`phonePad` / `namePhonePad`）か
  public var phoneNumber: SensitiveSignal

  public init(secureTextEntry: SensitiveSignal, phoneNumber: SensitiveSignal) {
    self.secureTextEntry = secureTextEntry
    self.phoneNumber = phoneNumber
  }

  /// 通常の入力欄
  public static let regular = KeyboardInputField(secureTextEntry: .off, phoneNumber: .off)

  /// 共有結果の挿入と本体アプリへの移動を提示しない理由。空なら制限のない入力欄。
  ///
  /// 拡張は共有コンテナを読む前にこれで確かめ、空でなければ共有結果を読まない（`KeyboardAvailability` と同じ判定）。
  public var restrictions: Set<KeyboardFieldRestriction> {
    var restrictions: Set<KeyboardFieldRestriction> = []
    switch secureTextEntry {
    case .on: restrictions.insert(.secureTextEntry)
    case .unknown: restrictions.insert(.undetermined)
    case .off: break
    }
    switch phoneNumber {
    case .on: restrictions.insert(.phoneNumber)
    case .unknown: restrictions.insert(.undetermined)
    case .off: break
    }
    return restrictions
  }
}

/// ネットワークの状態。
public enum NetworkReachability: Hashable, Sendable {
  case online
  case offline
  /// 観測できない（オフラインの案内を出さない）
  case unknown
}
