import AppKit
import SwiftUI
import UtterCore

/// `HUDPanel` に `HUDView` を載せて表示する（REC-03）。
///
/// パネルはキーウィンドウにならず VoiceOver のフォーカスも移らないため、失敗と通知は読み上げで知らせる。
/// 読み上げる文言は `HUDPresentation.announcement(after:)` だけで、本文を含まない。段階が変わるだけでは同じ通知を読み直さない。
@MainActor
final class HUDPanelPresenter: HUDPresenting {
  private let panel = HUDPanel()
  private var hostingView: NSHostingView<HUDView>?
  /// 表示中の内容。隠したら `nil`（次に表示したときは通知を読み上げ直す）
  private var shown: HUDPresentation?

  func show(_ presentation: HUDPresentation) {
    let view = HUDView(presentation: presentation)
    if let hostingView {
      hostingView.rootView = view
    } else {
      let hostingView = NSHostingView(rootView: view)
      // 大きさは HUDPanel が fittingSize で決めるため、ウィンドウの大きさの制約を書き換えさせない
      hostingView.sizingOptions = []
      panel.contentView = hostingView
      self.hostingView = hostingView
    }
    panel.present()
    let previous = shown
    shown = presentation
    if let announcement = presentation.announcement(after: previous) {
      NSAccessibility.post(
        element: NSApplication.shared,
        notification: .announcementRequested,
        userInfo: [
          .announcement: announcement,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
  }

  func hide() {
    shown = nil
    panel.orderOut(nil)
  }
}
