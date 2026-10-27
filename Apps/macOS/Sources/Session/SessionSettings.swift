import UtterCore

/// セッションの入力モード（2.2節）。保存値（UtterPersistence の `InputMode`）から `SessionSettings.fromSettings` で作る。
enum SessionInputMode: Hashable, Sendable, CaseIterable {
  /// 停止後にまとめて入力する（MVP 標準）
  case instant
  /// 録音中・認識中の認識テキストを HUD に出し、入力欄へは停止後にまとめて入力する（AC-03）
  case realtimePreview
  /// 確定済みチャンクを入力欄へ逐次書き込む（実験機能・MVP 外, AC-15）。使えなければ Instant と同じく停止後にまとめて入力する
  case realtimeDirect
}

/// セッションに使う録音・入力の設定（REC-05, 2.2節）。
///
/// 設定画面の保存値から作り（`fromSettings`）、`SessionCoordinator.useSettings(_:)` で渡すと次のセッションから使う。
/// 録音中・処理中のセッションは変えない
struct SessionSettings: Hashable, Sendable {
  /// 最大録音時間など、状態機械の構成（REC-05）
  var configuration: SessionConfiguration
  /// 入力モード（2.2節）。既定は Instant（MVP 標準）
  var inputMode: SessionInputMode

  init(
    configuration: SessionConfiguration = SessionConfiguration(),
    inputMode: SessionInputMode = .instant
  ) {
    self.configuration = configuration
    self.inputMode = inputMode
  }

  /// 入力モードが Realtime Preview か（認識テキストを HUD に出すか）
  var showsRealtimePreview: Bool {
    inputMode == .realtimePreview
  }
}
