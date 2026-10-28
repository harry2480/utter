import AppKit

/// HUD を載せる非アクティブ化パネル（REC-03）。
///
/// 表示してもアプリをアクティブにせず、キーウィンドウにもならないため、入力先アプリのフォーカスを奪わない。
/// クリックも受けずに下のウィンドウへ通す。全 Space とフルスクリーンのアプリの上にも表示する。
/// 画面の下部中央（Dock を除いた範囲の下端から間隔を空けた位置）に出す。
final class HUDPanel: NSPanel {
  /// 画面の下端（Dock を除いた範囲）からの間隔（仮置き）
  private static let bottomMargin: CGFloat = 48

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
  /// 表示を始めるときはマウスポインターのある画面の下部中央に置く。表示中は下端の中央を保ったまま大きさだけ変え
  /// （上へ伸び縮みする）、内容の更新のたびに別の画面へ移らないようにする。
  /// `visibleFrame` を使うため、Dock とメニューバーには重ならない。
  func present() {
    guard let contentView else { return }
    let size = contentView.fittingSize
    if isVisible {
      let next = NSRect(
        x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height)
      // 経過時間・レベルメーターの更新では大きさが変わらないため、置き直さない
      guard next != frame else { return }
      setFrame(next, display: true)
      // 透明な枠なしウィンドウの影は中身の形から作るため、大きさが変わったら描き直す
      invalidateShadow()
    } else {
      let visibleFrame = Self.screenUnderPointer()?.visibleFrame ?? .zero
      setFrame(
        NSRect(
          x: visibleFrame.midX - size.width / 2,
          y: visibleFrame.minY + Self.bottomMargin,
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
