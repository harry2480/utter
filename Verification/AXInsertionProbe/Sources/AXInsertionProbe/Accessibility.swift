import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Accessibility API の薄い包み。属性名は SDK の定数と同じ文字列を使う。
enum AXAttribute {
  static let focusedUIElement = "AXFocusedUIElement"
  static let focusedApplication = "AXFocusedApplication"
  static let role = "AXRole"
  static let subrole = "AXSubrole"
  static let value = "AXValue"
  static let selectedText = "AXSelectedText"
  static let selectedTextRange = "AXSelectedTextRange"
  static let secureTextFieldSubrole = "AXSecureTextField"
}

@MainActor
enum AX {
  /// 応答しないアプリで固まらないように、問い合わせの待ち時間を短くする
  static let messagingTimeout: Float = 1.0

  static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return error == .success ? value : nil
  }

  static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    copy(element, attribute) as? String
  }

  static func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  static func selectedRange(_ element: AXUIElement) -> CFRange? {
    guard let value = copy(element, AXAttribute.selectedTextRange),
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else {
      return nil
    }
    return range
  }

  static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    return error == .success && settable.boolValue
  }

  static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
    AXUIElementSetAttributeValue(element, attribute as CFString, value)
  }

  static func setSelectedRange(_ element: AXUIElement, _ range: CFRange) -> AXError {
    var range = range
    guard let value = AXValueCreate(.cfRange, &range) else { return .failure }
    return set(element, AXAttribute.selectedTextRange, value)
  }

  /// フォーカス中の要素。システム全体から取れないアプリ（Electron など）は、フォーカス中のアプリ経由で取る。
  static func focusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
    if let element = element(copy(systemWide, AXAttribute.focusedUIElement)) {
      return element
    }
    let app =
      element(copy(systemWide, AXAttribute.focusedApplication))
      ?? frontmostApplicationPID().map(AXUIElementCreateApplication)
    guard let app else { return nil }
    AXUIElementSetMessagingTimeout(app, messagingTimeout)
    return element(copy(app, AXAttribute.focusedUIElement))
  }

  /// フォーカス中のアプリの pid。RunLoop を回さない CLI では NSWorkspace の最前面アプリが古いままになりうるため、
  /// AX から取る
  static func focusedApplicationPID() -> pid_t? {
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
    return element(copy(systemWide, AXAttribute.focusedApplication)).flatMap(pid)
      ?? frontmostApplicationPID()
  }

  /// macOS 27.0.1 では、システム全体の要素への問い合わせ（AXFocusedUIElement・AXFocusedApplication）が
  /// kAXErrorCannotComplete を返し、アプリの要素への問い合わせは通ることがある。そのときは NSWorkspace の最前面アプリを使う。
  /// RunLoop を回さない CLI では値が古いままになりうるため、少しだけ回して更新させる
  static func frontmostApplicationPID() -> pid_t? {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
  }

  static func pid(_ element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    return AXUIElementGetPid(element, &pid) == .success ? pid : nil
  }
}

/// 挿入対象として記録した入力欄。値の中身は記録・表示しない。
@MainActor
struct FocusedTarget {
  let element: AXUIElement
  let pid: pid_t
  let bundleID: String
  let appVersion: String
  let role: String
  let subrole: String

  static func current() -> FocusedTarget? {
    guard let element = AX.focusedElement(), let pid = AX.pid(element) else { return nil }
    AXUIElementSetMessagingTimeout(element, AX.messagingTimeout)
    let app = NSRunningApplication(processIdentifier: pid)
    let bundle = app?.bundleURL.flatMap(Bundle.init(url:))
    return FocusedTarget(
      element: element,
      pid: pid,
      bundleID: app?.bundleIdentifier ?? "unknown",
      appVersion: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown",
      role: AX.string(element, AXAttribute.role) ?? "unknown",
      subrole: AX.string(element, AXAttribute.subrole) ?? ""
    )
  }

  var isSecureField: Bool { subrole == AXAttribute.secureTextFieldSubrole }

  /// 改行が Enter として実行される危険があるアプリ（INS-03）
  var isTerminal: Bool {
    [
      "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
      "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "org.alacritty", "io.alacritty",
      "com.github.wez.wezterm",
    ].contains(bundleID)
  }

  func isSameElement(as other: FocusedTarget) -> Bool {
    pid == other.pid && CFEqual(element, other.element)
  }
}

@MainActor
enum Permissions {
  static func isAccessibilityTrusted(prompt: Bool) -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  static func canPostEvents(request: Bool) -> Bool {
    if CGPreflightPostEventAccess() { return true }
    return request ? CGRequestPostEventAccess() : false
  }

  /// パスワード入力中などでセキュア入力が有効か
  static var isSecureEventInputEnabled: Bool { IsSecureEventInputEnabled() }

  static let guidance = """
    Accessibility の権限がありません。
    システム設定 → プライバシーとセキュリティ → アクセシビリティ で、このコマンドを実行している
    ターミナルアプリ（ターミナル / iTerm など）を許可してから、ターミナルを再起動してください。
    `ax-insertion-probe check --prompt` で許可ダイアログを出せます。
    検証が終わったら、同じ画面で許可を外してください。
    """
}
