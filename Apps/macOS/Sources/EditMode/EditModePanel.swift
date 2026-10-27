import AppKit
import SwiftUI
import UtterCore
import UtterText

/// Edit Mode の差分プレビュー（確定・キャンセル）と通知のパネル（AC-14）。
///
/// 前面のアプリからフォーカスを奪わない浮動パネルにする（入力欄の選択範囲を保つため）。
/// 自動で置き換え・復元できなかった文字列は `InsertionPreviewPanel` のコピーできるパネルへ退避する。
/// HUD（#141）とは独立した最小限の表示で、HUD ができたら通知は HUD に寄せる。
/// 音声指示の録音中・認識中・応答待ちは、キャンセルできる表示（`showStatus(_:)`）を次の表示まで出す。
@MainActor
final class EditModePanel: EditModePresenting {
  /// 確定ボタン。組み立て時に `EditModeCoordinator.commit()` へつなぐ
  var onCommit: (() -> Void)?
  /// キャンセルボタン（差分プレビューと進行中の表示）。組み立て時に `EditModeController.cancel()` へつなぐ
  var onCancel: (() -> Void)?

  private let fallback: InsertionPreviewPanel
  private var proposalPanel: NSPanel?
  private var statusPanel: NSPanel?
  private var noticePanel: NSPanel?
  private var noticeDismissal: Task<Void, Never>?

  /// 通知を表示しておく時間
  static let noticeDuration: Duration = .seconds(4)

  init(fallback: InsertionPreviewPanel) {
    self.fallback = fallback
  }

  func showProposal(_ proposal: EditProposal) {
    let panel =
      proposalPanel
      ?? Self.makePanel(title: "utter — Edit の差分", size: NSSize(width: 480, height: 320))
    panel.contentView = NSHostingView(
      rootView: EditProposalView(
        diff: proposal.diff,
        commit: { [weak self] in self?.onCommit?() },
        cancel: { [weak self] in self?.onCancel?() }))
    if proposalPanel == nil {
      panel.center()
      proposalPanel = panel
    }
    panel.orderFrontRegardless()
  }

  func dismissProposal() {
    // 閉じたパネルに編集案を残さない
    proposalPanel?.contentView = nil
    proposalPanel?.orderOut(nil)
    proposalPanel = nil
  }

  func showNotice(_ notice: EditModeNotice) {
    let panel =
      noticePanel ?? Self.makePanel(title: "utter — Edit", size: NSSize(width: 360, height: 96))
    panel.contentView = NSHostingView(
      rootView: Text(EditModeMessage.text(for: notice))
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(minWidth: 320, alignment: .leading))
    if noticePanel == nil {
      panel.center()
      noticePanel = panel
    }
    panel.orderFrontRegardless()
    noticeDismissal?.cancel()
    noticeDismissal = Task { [weak self] in
      try? await Task.sleep(for: Self.noticeDuration)
      guard !Task.isCancelled else { return }
      self?.noticePanel?.orderOut(nil)
    }
  }

  func showFallback(text: String, cause: EditFallbackCause) {
    fallback.showPreview(text: text, message: EditModeMessage.text(for: cause))
  }

  func showStatus(_ status: EditModeStatus?) {
    guard let status else {
      statusPanel?.contentView = nil
      statusPanel?.orderOut(nil)
      statusPanel = nil
      return
    }
    let panel =
      statusPanel
      ?? Self.makePanel(title: "utter — Edit", size: NSSize(width: 360, height: 110))
    panel.contentView = NSHostingView(
      rootView: EditStatusView(
        text: EditModeMessage.text(for: status),
        cancel: { [weak self] in self?.onCancel?() }))
    if statusPanel == nil {
      panel.center()
      statusPanel = panel
    }
    panel.orderFrontRegardless()
  }

  private static func makePanel(title: String, size: NSSize) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .resizable, .nonactivatingPanel, .utilityWindow],
      backing: .buffered, defer: true)
    panel.title = title
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    // ボタンを押してもキーウィンドウにならず、入力欄のフォーカスと選択範囲を保つ
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return panel
  }
}

/// 録音中・認識中・応答待ちの表示と、キャンセルのボタン。
private struct EditStatusView: View {
  let text: String
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("キャンセル", action: cancel)
      }
    }
    .padding(16)
    .frame(minWidth: 320, alignment: .leading)
  }
}

/// 差分（削除は取り消し線、挿入は強調）と、確定・キャンセルのボタン。
private struct EditProposalView: View {
  let diff: TextDiff
  let commit: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if diff.precision == .approximate {
        Text("長い文章のため、変更箇所をまとめて表示しています。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      ScrollView {
        Text(Self.attributed(diff))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
      }
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      HStack {
        Text("確定すると選択範囲を置き換えます。")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
        Button("キャンセル", action: cancel)
        Button("確定", action: commit)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(16)
    .frame(minWidth: 420, minHeight: 240)
  }

  static func attributed(_ diff: TextDiff) -> AttributedString {
    var result = AttributedString()
    for segment in diff.segments {
      var part = AttributedString(segment.text)
      switch segment.kind {
      case .unchanged:
        break
      case .deleted:
        part.strikethroughStyle = .single
        part.foregroundColor = .red
        part.backgroundColor = .red.opacity(0.12)
      case .inserted:
        part.foregroundColor = .green
        part.backgroundColor = .green.opacity(0.15)
        part.underlineStyle = .single
      }
      result += part
    }
    return result
  }
}
