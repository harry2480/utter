/// キーボード拡張が表示時に観測できる状態（iOS-09, iAC-06, iAC-07）。拡張側が OS の状態から作る。
///
/// キーボード禁止アプリでは OS が拡張を起動しないため、ここには現れない。拡張から検出・回避する手段は作らない。
public struct KeyboardEnvironment: Hashable, Sendable {
  /// 「フルアクセスを許可」が有効か（`UIInputViewController.hasFullAccess`）
  public var hasFullAccess: Bool
  /// App Group の共有コンテナを読めるか。読めなければ共有結果を表示・挿入できない
  public var canAccessSharedContainer: Bool
  /// 現在の入力欄
  public var inputField: KeyboardInputField
  /// 本体アプリの状態。本体アプリが一度も状態を残していない、または読めなければ `nil`
  public var hostApp: HostAppStatus?

  public init(
    hasFullAccess: Bool,
    canAccessSharedContainer: Bool,
    inputField: KeyboardInputField,
    hostApp: HostAppStatus?
  ) {
    self.hasFullAccess = hasFullAccess
    self.canAccessSharedContainer = canAccessSharedContainer
    self.inputField = inputField
    self.hostApp = hostApp
  }
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
}
