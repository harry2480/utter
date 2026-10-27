import AppKit
import ApplicationServices
import Foundation
import UtterCore

/// 前面のブラウザで表示中のページのホスト名を読む口（CTX-02, CTX-03）。
///
/// 本番は `AccessibilitySiteHostReader`、テストは Stub を使う。呼び出し側（`SessionRefinementPipeline`）は、
/// サイト単位の識別が許可され、サイト別の上書きがあるとき（`SiteStyleResolver.needsSiteHost`）だけ呼ぶ。
/// 返すのはホスト名だけで、URL は返さない。ホスト名はスタイルの判定にだけ使い、保持・送信・記録しない。
protocol FrontmostSiteHostReading: Sendable {
  /// `bundleID` のアプリが前面にあるとき、そのアプリで表示中のページのホスト名。
  /// 前面のアプリが違う・ブラウザでない・読めない・Accessibility が未許可なら `nil`（アプリ別のスタイルに戻る）
  @MainActor func siteHost(inFrontmostApp bundleID: String) -> SiteHost?
}

/// Accessibility API で、前面のブラウザの Web 領域（`AXWebArea`）の URL（`AXURL`）からホスト名だけを取り出す。
///
/// AppleScript・Apple Events・非公開 API は使わず、挿入と同じ Accessibility の権限だけを使う（権限がなければ何もしない）。
/// フォーカス中の要素から親をたどって Web 領域を探し、見つからなければフォーカス中のウインドウの中を数を限って探す。
/// 問い合わせはメインスレッドで行うため、待ち時間を短くし（`messagingTimeout`）、たどる要素の数と
/// 探索全体の時間（`searchTimeLimit`）を限る。読み終えたときに前面のアプリが替わっていたら使わない。
/// 応答しないアプリでは最初の問い合わせで諦める。読んだ URL はその場でホスト名に変え、保持しない。
///
/// Chromium 系のブラウザは、支援技術から要求されるまで Web 領域を公開しないことがある。
/// 公開を求める属性（`AXManualAccessibility` など）は他アプリの状態を変えるため設定せず、読めなければ `nil` にする。
struct AccessibilitySiteHostReader: FrontmostSiteHostReading {
  /// 1回の問い合わせの待ち時間（秒）。挿入（`AccessibilityInsertionTarget.messagingTimeout`）より短くする
  static let messagingTimeout: Float = 0.25
  /// フォーカス中の要素から親をたどる上限
  static let maxAncestorDepth = 64
  /// フォーカス中のウインドウの中で調べる要素の数の上限
  static let maxSearchedElements = 200
  /// フォーカス中のウインドウの中を探す深さの上限
  static let maxSearchDepth = 12
  /// 探索全体にかける時間の上限（秒）。過ぎたら読めなかったものとしてアプリ別のスタイルに戻す。
  /// 問い合わせごとの待ち時間（`messagingTimeout`）だけでは、多くの要素を調べたときの合計を抑えられないため
  static let searchTimeLimit: Duration = .milliseconds(300)

  private enum Attribute {
    static let focusedUIElement = "AXFocusedUIElement"
    static let focusedWindow = "AXFocusedWindow"
    static let parent = "AXParent"
    static let children = "AXChildren"
    static let role = "AXRole"
    static let url = "AXURL"
    static let webAreaRole = "AXWebArea"
  }

  /// 問い合わせを打ち切る理由
  private enum Stop: Error {
    /// アプリが応答しない・Accessibility の利用が拒否された・探索の時間の上限を過ぎた
    case unavailable
  }

  /// 探索の期限。`siteHost(inFrontmostApp:)` を呼ぶたびに決める
  private let deadline: ContinuousClock.Instant

  init() {
    deadline = .now
  }

  private init(deadline: ContinuousClock.Instant) {
    self.deadline = deadline
  }

  @MainActor func siteHost(inFrontmostApp bundleID: String) -> SiteHost? {
    guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier == bundleID
    else { return nil }
    let processIdentifier = app.processIdentifier
    let search = Self(deadline: .now + Self.searchTimeLimit)
    guard let host = search.siteHost(inProcess: processIdentifier) else { return nil }
    // 問い合わせの間に前面のアプリが替わっていたら、前のアプリのホスト名は使わない
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
      return nil
    }
    return host
  }

  /// `processIdentifier` のアプリで表示中のページのホスト名。期限（`deadline`）を過ぎたら `nil`
  private func siteHost(inProcess processIdentifier: pid_t) -> SiteHost? {
    let application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
    do {
      if let focused = try element(application, Attribute.focusedUIElement),
        let webArea = try enclosingWebArea(of: focused)
      {
        return try siteHost(of: webArea)
      }
      guard let window = try element(application, Attribute.focusedWindow),
        let webArea = try firstWebArea(in: window)
      else { return nil }
      return try siteHost(of: webArea)
    } catch {
      return nil
    }
  }

  /// AX の `AXURL` の値（`URL` / `NSURL` / 文字列）からホスト名だけを取り出す。
  /// `http` / `https` 以外・ホスト名のない値は `nil`。URL はこの中だけで使い、返さない
  static func siteHost(fromURLValue value: Any?) -> SiteHost? {
    if let url = value as? URL {
      return SiteHost(url: url)
    }
    if let string = value as? String, let url = URL(string: string) {
      return SiteHost(url: url)
    }
    return nil
  }

  // MARK: - AX

  /// フォーカス中の要素かその祖先の Web 領域
  private func enclosingWebArea(of element: AXUIElement) throws(Stop) -> AXUIElement? {
    var current: AXUIElement? = element
    for _ in 0..<Self.maxAncestorDepth {
      guard let candidate = current else { return nil }
      if try isWebArea(candidate) { return candidate }
      current = try self.element(candidate, Attribute.parent)
    }
    return nil
  }

  /// ウインドウの中で最初に見つかった Web 領域（幅優先、数と深さを限る）
  private func firstWebArea(in window: AXUIElement) throws(Stop) -> AXUIElement? {
    var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
    var index = 0
    while index < queue.count, index < Self.maxSearchedElements {
      let (candidate, depth) = queue[index]
      index += 1
      if try isWebArea(candidate) { return candidate }
      guard depth < Self.maxSearchDepth else { continue }
      for child in try children(of: candidate) {
        queue.append((child, depth + 1))
      }
    }
    return nil
  }

  private func siteHost(of webArea: AXUIElement) throws(Stop) -> SiteHost? {
    try Self.siteHost(fromURLValue: copy(webArea, Attribute.url))
  }

  private func isWebArea(_ element: AXUIElement) throws(Stop) -> Bool {
    let role = try copy(element, Attribute.role) as? String
    return role == Attribute.webAreaRole
  }

  private func children(of element: AXUIElement) throws(Stop) -> [AXUIElement] {
    guard let value = try copy(element, Attribute.children) as? [AnyObject] else { return [] }
    return value.compactMap { axElement($0) }
  }

  private func element(_ element: AXUIElement, _ attribute: String) throws(Stop) -> AXUIElement? {
    try axElement(copy(element, attribute))
  }

  /// 属性の値。値がない・対応しない属性は `nil`、応答しない・拒否されたら打ち切る
  private func copy(_ element: AXUIElement, _ attribute: String) throws(Stop) -> CFTypeRef? {
    guard ContinuousClock.now < deadline else { throw .unavailable }
    AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
    case .success:
      return value
    case .cannotComplete, .apiDisabled, .notImplemented:
      throw .unavailable
    default:
      return nil
    }
  }

  private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }
}
