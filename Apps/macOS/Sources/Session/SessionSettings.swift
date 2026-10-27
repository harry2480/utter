import UtterCore

/// セッションに使う録音・入力の設定（REC-05, 2.2節）。
///
/// 設定画面の保存値から作り（`fromSettings`）、`SessionCoordinator.useSettings(_:)` で渡すと次のセッションから使う。
/// 録音中・処理中のセッションは変えない
struct SessionSettings: Hashable, Sendable {
  /// 最大録音時間など、状態機械の構成（REC-05）
  var configuration: SessionConfiguration
  /// 入力モードが Realtime Preview か（2.2節）。`false` は Instant（MVP 標準）
  var showsRealtimePreview: Bool

  init(
    configuration: SessionConfiguration = SessionConfiguration(), showsRealtimePreview: Bool = false
  ) {
    self.configuration = configuration
    self.showsRealtimePreview = showsRealtimePreview
  }
}
