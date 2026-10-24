import UtterCore

/// アプリ全体で1つずつ持つ部品の組み立て（Composition Root）。
///
/// 録音・STT・挿入を結線したら、セッションを進める側が `SessionStateMachine` を変えるたびに
/// `hud.update(from:)` を呼び、`hud.onErrorDisplayExpired` で `dismissError()` を呼ぶ。
@MainActor
final class AppComposition {
  let hud = HUDController(
    presenter: HUDPanelPresenter(),
    scheduler: TaskHUDRefreshScheduler()
  )

  #if DEBUG
    private(set) lazy var hudDemo = HUDDemo(hud: hud)
  #endif
}
