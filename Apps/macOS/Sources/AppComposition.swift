import Observation
import UtterCore

/// アプリ全体で1つずつ持つ部品の組み立て（Composition Root）。
///
/// 録音・STT・挿入を結線したら、セッションを進める側が `SessionStateMachine` を変えるたびに
/// `hud.update(from:)` を呼び、`hud.onErrorDisplayExpired` で `dismissError()` を呼ぶ。
@MainActor
@Observable
final class AppComposition {
  let hud = HUDController(
    presenter: HUDPanelPresenter(),
    scheduler: TaskHUDRefreshScheduler()
  )

  #if DEBUG
    // `@Observable` は lazy のプロパティを追跡できないため、追跡の対象から外す
    @ObservationIgnored private(set) lazy var hudDemo = HUDDemo(hud: hud)
  #endif
}
