import AppKit
import SwiftUI
import UtterCore

/// `HUDPanel` に `HUDView` を載せて表示する（REC-03）。
///
/// パネルはキーウィンドウにならず VoiceOver のフォーカスも移らないため、失敗と通知は読み上げで知らせる。
/// 読み上げる文言は `HUDPresentation.announcement(after:)` だけで、本文（Realtime Preview の認識テキスト）を含まない。
/// 段階が変わるだけ・認識テキストが変わるだけでは同じ通知を読み直さない。
///
/// 表示・非表示の依頼はその場では画面に反映せず、`HUDDisplayQueue` に溜めてメインスレッドの次の処理でまとめて反映する。
/// Esc のイベントタップのコールバック（キャンセル）の中で、ウィンドウの操作をしないため（REC-01）。
/// Realtime Preview の認識テキストが短い間隔で届いても、最後の内容だけを描画する（AC-03）。
@MainActor
final class HUDPanelPresenter: HUDPresenting {
  private let panel = HUDPanel()
  private var hostingView: NSHostingView<HUDView>?
  private var queue = HUDDisplayQueue()

  func show(_ presentation: HUDPresentation) {
    schedule { $0.requestShow(presentation) }
  }

  func hide() {
    schedule { $0.requestHide() }
  }

  private func schedule(_ request: (inout HUDDisplayQueue) -> Void) {
    let isScheduled = queue.hasPending
    request(&queue)
    guard !isScheduled else { return }
    Task { @MainActor [weak self] in
      self?.flush()
    }
  }

  private func flush() {
    for step in queue.flush() {
      switch step {
      case .hide:
        panel.orderOut(nil)
      case .show(let presentation, let announcement):
        present(presentation, announcement: announcement)
      }
    }
  }

  private func present(_ presentation: HUDPresentation, announcement: String?) {
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
    if let announcement {
      NSAccessibility.post(
        element: NSApplication.shared,
        notification: .announcementRequested,
        userInfo: [
          .announcement: announcement,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
  }
}
