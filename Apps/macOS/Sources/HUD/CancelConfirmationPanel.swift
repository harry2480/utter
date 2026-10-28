import AppKit

/// 処理中にもう一度ショートカットを押したときに出す、キャンセルの確認（REC-06, #199）。
///
/// HUD と同じく非アクティブ化パネルに載せ、アプリをアクティブにせず、キーウインドウにもならない。
/// 入力先アプリのフォーカスを奪わないため、確認を出している間に処理が終わっても、挿入先は変わらない
/// （処理が終わったら `SessionCancelConfirmation` が答えを待たずに閉じる）。ボタンはクリックでだけ選べ、キー入力は受けない。
/// 発話本文は出さない。
@MainActor
final class CancelConfirmationPanel: NSObject, SessionCancelConfirmationPresenting {
  /// 画面上端（メニューバーの下）からの間隔。上端の HUD と重ならないよう下げて出す
  private static let topMargin: CGFloat = 96

  private var panel: ConfirmationPanel?
  private var onAnswer: (@MainActor (Bool) -> Void)?

  func present(onAnswer: @escaping @MainActor (Bool) -> Void) {
    self.onAnswer = onAnswer
    let panel = self.panel ?? makePanel()
    self.panel = panel
    guard let contentView = panel.contentView else { return }
    let size = contentView.fittingSize
    let visibleFrame = Self.screenUnderPointer()?.visibleFrame ?? .zero
    panel.setFrame(
      NSRect(
        x: visibleFrame.midX - size.width / 2,
        y: visibleFrame.maxY - Self.topMargin - size.height,
        width: size.width,
        height: size.height),
      display: true)
    // アプリをアクティブにせずに前面へ出す
    panel.orderFrontRegardless()
  }

  func dismiss() {
    onAnswer = nil
    panel?.orderOut(nil)
  }

  @objc private func confirmCancel(_ sender: Any?) {
    answer(true)
  }

  @objc private func keepProcessing(_ sender: Any?) {
    answer(false)
  }

  private func answer(_ confirmed: Bool) {
    let onAnswer = self.onAnswer
    dismiss()
    onAnswer?(confirmed)
  }

  private func makePanel() -> ConfirmationPanel {
    let panel = ConfirmationPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow

    let message = NSTextField(labelWithString: "処理中の入力をキャンセルしますか？")
    message.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    let detail = NSTextField(labelWithString: "キャンセルすると、この入力は入力欄に入りません。")
    detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    detail.textColor = .secondaryLabelColor
    let keep = FirstMouseButton(title: "続ける", target: self, action: #selector(keepProcessing(_:)))
    let cancel = FirstMouseButton(
      title: "キャンセルする", target: self, action: #selector(confirmCancel(_:)))
    let buttons = NSStackView(views: [keep, cancel])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    let stack = NSStackView(views: [message, detail, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let background = NSVisualEffectView()
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 12
    background.layer?.masksToBounds = true
    background.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      stack.topAnchor.constraint(equalTo: background.topAnchor),
      stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    panel.contentView = background
    return panel
  }

  private static func screenUnderPointer() -> NSScreen? {
    let location = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
  }
}

/// キーウインドウにもメインウインドウにもならないパネル。入力先アプリのフォーカスを奪わない
private final class ConfirmationPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// キーウインドウでないパネルでも、最初のクリックで押せるボタン
private final class FirstMouseButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
