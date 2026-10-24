import AppKit
import SwiftUI
import UtterCore

/// プレビューに出す、自動挿入しなかった理由の文言（AC-09）。文字列の中身は含めない。
enum InsertionPreviewMessage {
  static func text(for cause: InsertionPreviewCause) -> String {
    switch cause {
    case .plan(.targetUnknown):
      "録音開始時の入力欄を確認できなかったため、自動で入力しませんでした。"
    case .plan(.targetMissing):
      "入力欄が見つからないため、自動で入力しませんでした。"
    case .plan(.targetChanged):
      "録音開始時と入力欄が変わったため、自動で入力しませんでした。"
    case .plan(.allRoutesFailed):
      "このアプリへ自動で入力できませんでした。"
    case .plan(.noAvailableRoute):
      "このアプリで使える自動入力の方法がない（キー入力の送信が許可されていないなど）ため、自動で入力しませんでした。"
    case .plan(.multilineInTerminal):
      "改行がコマンドの実行にならないよう、ターミナルへは自動で入力しませんでした。"
    case .sensitiveInput:
      "パスワード欄など、自動で入力しない入力先のため入力しませんでした。"
    case .accessibilityNotTrusted:
      "アクセシビリティが許可されていないため、自動で入力しませんでした。システム設定で utter を許可してください。"
    case .insertionInProgress:
      "前の入力の途中だったため、自動で入力しませんでした。"
    case .cancelled:
      "入力が取り消されたため、自動で入力しませんでした。"
    case .realtimeDirectStopped(_, wroteText: true):
      "入力欄が変更された、またはフォーカスが移ったなどのため、途中から自動で入力しませんでした。途中までは入力欄に入っています。全体をコピーできます。"
    case .realtimeDirectStopped(_, wroteText: false):
      "入力欄が変更された、またはフォーカスが移ったなどのため、自動で入力しませんでした。"
    }
  }
}

/// 自動挿入しなかった文字列を、コピーできるパネルで表示する（INS-01〜03, AC-09）。
///
/// 前面のアプリからフォーカスを奪わない浮動パネルにする。退避が続いても前の文字列を上書きしないよう、
/// 1件ごとに別のパネルを開く。閉じたら文字列を手放す。
/// HUD（#141）とは独立した最小限の表示で、HUD ができたら HUD から開く形に寄せる。
@MainActor
final class InsertionPreviewPanel: NSObject, InsertionPreviewPresenting, NSWindowDelegate {
  private let pasteboard: NSPasteboard
  private var panels: [NSPanel] = []

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  func showPreview(text: String, cause: InsertionPreviewCause) {
    let panel = makePanel()
    let view = InsertionPreviewView(
      text: text, message: InsertionPreviewMessage.text(for: cause),
      copy: { [weak self, weak panel] in
        guard let self, let panel else { return }
        self.copy(text, closing: panel)
      },
      close: { [weak panel] in panel?.close() })
    panel.contentView = NSHostingView(rootView: view)
    panel.center()
    if let last = panels.last {
      // 前のパネルと重ならないよう少しずらす
      panel.setFrameTopLeftPoint(
        NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
    }
    panels.append(panel)
    panel.orderFrontRegardless()
  }

  /// 利用者が明示的にコピーする。発話の内容をクリップボード管理アプリの履歴に残さないよう印を付ける（INS-06）。
  /// 書き込めなければ、文字列を失わないようパネルを閉じない
  private func copy(_ text: String, closing panel: NSPanel) {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    for marker in ClipboardMarker.all {
      item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
    }
    pasteboard.clearContents()
    if pasteboard.writeObjects([item]) {
      panel.close()
    } else {
      NSSound.beep()
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
      backing: .buffered, defer: true)
    panel.title = "utter — 入力しなかった文字列"
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.delegate = self
    return panel
  }

  func windowWillClose(_ notification: Notification) {
    guard let panel = notification.object as? NSPanel else { return }
    // 閉じたパネルに文字列を残さない
    panel.contentView = nil
    panels.removeAll { $0 === panel }
  }
}

private struct InsertionPreviewView: View {
  let text: String
  let message: String
  let copy: () -> Void
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        Text(text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
      }
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      HStack {
        Spacer()
        Button("閉じる", action: close)
          .keyboardShortcut(.cancelAction)
        Button("コピーして閉じる", action: copy)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(minWidth: 360, minHeight: 200)
  }
}
