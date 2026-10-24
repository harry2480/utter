import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import UtterCore

/// Accessibility API による入力対象の取得と読み書き（INS-01, INS-02, INS-05）。
///
/// AXInsertionProbe（#41）と同じ方法を使う。入力欄の値はメモリ上の比較にだけ使い、記録・表示しない。
/// Accessibility が未許可なら、フォーカス中の要素は取れず（`nil`）、書き込みは送信前の失敗になる。
@MainActor
final class AccessibilityInsertionTarget: InsertionTargetInspector, InsertionFieldAccess {
  /// 応答しないアプリで固まらないように、問い合わせの待ち時間を短くする（秒）
  static let messagingTimeout: Float = 1.0

  private enum Attribute {
    static let focusedUIElement = "AXFocusedUIElement"
    static let focusedApplication = "AXFocusedApplication"
    static let subrole = "AXSubrole"
    static let value = "AXValue"
    static let selectedText = "AXSelectedText"
    static let selectedTextRange = "AXSelectedTextRange"
    static let secureTextFieldSubrole = "AXSecureTextField"
  }

  private struct Element {
    let element: AXUIElement
    let pid: pid_t
  }

  private var registry = TargetIdentityRegistry<Element>(
    isSame: { $0.pid == $1.pid && CFEqual($0.element, $1.element) },
    makeID: { InsertionTargetID(rawValue: UUID().uuidString) })

  // MARK: InsertionTargetInspector

  func recordTarget() -> InsertionTargetID? {
    guard let focused = focusedElement() else {
      registry.clear()
      return nil
    }
    return registry.record(focused)
  }

  func focusedTarget() -> FocusedInsertionTarget? {
    guard let focused = focusedElement() else { return nil }
    return FocusedInsertionTarget(
      id: registry.identify(focused),
      app: NSRunningApplication(processIdentifier: focused.pid)?.bundleIdentifier,
      secureField: secureFieldSignal(focused.element))
  }

  func secureEventInput() -> SensitiveSignal {
    IsSecureEventInputEnabled() ? .on : .off
  }

  // MARK: InsertionFieldAccess

  func snapshot(of target: InsertionTargetID) -> FieldSnapshot {
    guard let element = registry.element(for: target)?.element else {
      return FieldSnapshot(value: nil, selection: nil)
    }
    return FieldSnapshot(value: string(element, Attribute.value), selection: selection(element))
  }

  func value(of target: InsertionTargetID) -> String? {
    registry.element(for: target).flatMap { string($0.element, Attribute.value) }
  }

  func insertAtSelection(_ text: String, into target: InsertionTargetID) -> InsertionResponse {
    guard let element = registry.element(for: target)?.element,
      isSettable(element, Attribute.selectedText)
    else { return .rejectedBeforeSend }
    let error = AXUIElementSetAttributeValue(
      element, Attribute.selectedText as CFString, text as CFString)
    return error == .success ? .succeeded : .failedAfterSend
  }

  // MARK: - AX

  /// フォーカス中の要素。システム全体から取れないアプリ（Electron など）は、フォーカス中のアプリ経由で取る
  private func focusedElement() -> Element? {
    guard AXIsProcessTrusted() else { return nil }
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
    var element = axElement(copy(systemWide, Attribute.focusedUIElement))
    if element == nil, let app = axElement(copy(systemWide, Attribute.focusedApplication)) {
      AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
      element = axElement(copy(app, Attribute.focusedUIElement))
    }
    guard let element else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return nil }
    AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    return Element(element: element, pid: pid)
  }

  /// セキュア入力欄か。subrole がない要素は該当しない。問い合わせ自体が失敗したら判定できない（7章）。
  ///
  /// subrole のない入力欄（多くの NSTextView・Web の textarea など）を判定できない扱いにすると、ほぼすべての入力欄で挿入できなくなる。
  /// パスワード欄は AppKit・WebKit では `AXSecureTextField` を公開し（ほかのアプリは要実機確認）、多くはフォーカス中にシステムのセキュア入力も有効にするため、
  /// 両方の信号を併用して判定する（7章）
  private func secureFieldSignal(_ element: AXUIElement) -> SensitiveSignal {
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, Attribute.subrole as CFString, &value) {
    case .success:
      return (value as? String) == Attribute.secureTextFieldSubrole ? .on : .off
    case .noValue, .attributeUnsupported:
      return .off
    default:
      return .unknown
    }
  }

  private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return error == .success ? value : nil
  }

  private func string(_ element: AXUIElement, _ attribute: String) -> String? {
    copy(element, attribute) as? String
  }

  private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func selection(_ element: AXUIElement) -> FieldSnapshot.Selection? {
    guard let value = copy(element, Attribute.selectedTextRange),
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else {
      return nil
    }
    return FieldSnapshot.Selection(location: range.location, length: range.length)
  }

  private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    return error == .success && settable.boolValue
  }
}
