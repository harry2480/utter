import AppKit

/// HUD を載せる非アクティブ化パネル（REC-03）。
///
/// 表示してもアプリをアクティブにせず、キーウィンドウにもならないため、入力先アプリのフォーカスを奪わない。
/// クリックも受けずに下のウィンドウへ通す。全 Space とフルスクリーンのアプリの上にも表示する。
final class HUDPanel: NSPanel {
  /// 画面上端（メニューバーの下）からの間隔
  private static let topMargin: CGFloat = 12

  convenience init() {
    self.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    ignoresMouseEvents = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    animationBehavior = .utilityWindow
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// `contentView` の大きさに合わせて表示する。
  ///
  /// 表示を始めるときはマウスポインターのある画面の上端中央に置く。表示中は上端中央を保ったまま大きさだけ変え、
  /// 内容の更新のたびに別の画面へ移らないようにする。
  func present() {
    guard let contentView else { return }
    let size = contentView.fittingSize
    if isVisible {
      let top = frame.maxY
      let midX = frame.midX
      setFrame(
        NSRect(
          x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
        display: true)
      // 透明な枠なしウィンドウの影は中身の形から作るため、大きさが変わったら描き直す
      invalidateShadow()
    } else {
      let visibleFrame = Self.screenUnderPointer()?.visibleFrame ?? .zero
      setFrame(
        NSRect(
          x: visibleFrame.midX - size.width / 2,
          y: visibleFrame.maxY - Self.topMargin - size.height,
          width: size.width,
          height: size.height),
        display: true)
      // アプリをアクティブにせずに前面へ出す
      orderFrontRegardless()
    }
  }

  private static func screenUnderPointer() -> NSScreen? {
    let location = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
  }
}
