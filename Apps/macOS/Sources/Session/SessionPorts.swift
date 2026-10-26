import UtterCore
import UtterSpeech

// セッションの調停（SessionCoordinator）が使う部品の境界。本番は挿入・タイマーのアダプター、
// テストは Stub を渡す。どれも発話本文を記録・表示しない。

/// 録音開始時に記録した入力対象（INS-01, CTX-01）。値の中身は持たない。
struct RecordedInsertionTarget: Hashable, Sendable {
  /// 入力対象の識別子。取得できなければ `nil`（挿入時にプレビューへ退避する）
  let id: InsertionTargetID?
  /// 前面アプリの識別子（bundle ID）。整形のスタイル区分（CTX-01）の判定にだけ使う
  let app: String?
}

/// 入力対象の記録と挿入（INS-01〜07, AC-09）。
@MainActor
protocol SessionTextInserting: AnyObject {
  /// 録音開始時に呼び、その時点のフォーカス中の入力対象を記録する
  func recordTarget() -> RecordedInsertionTarget
  /// 文字列を挿入する。自動挿入できなければコピー可能なプレビューへ退避する
  func insert(_ text: String, into target: RecordedInsertionTarget) async -> InsertionReport
}

/// 最大録音時間（REC-05）に録音を止めるための予約。本番はタイマー、テストは Stub で時刻を進める。
@MainActor
protocol SessionDeadlineScheduling: AnyObject {
  /// `deadline` に `action` を1回呼ぶよう予約する。前の予約は取り消す。`deadline` が `nil` なら取り消すだけ。
  func schedule(at deadline: ContinuousClock.Instant?, _ action: @escaping @MainActor () -> Void)
}

extension TaskHUDRefreshScheduler: SessionDeadlineScheduling {}

/// 一時音声の保存と復旧の差し込み口（7章, AC-10）。
///
/// 本番は `TemporaryAudioRetention`（届いたチャンクを `RecordedAudio` に溜め、録音の終わりに `TemporaryAudioStore` へ保存し、
/// セッションの終わりに削除する）。docs/アーキテクチャ.md「一時音声と再処理」
@MainActor
protocol SessionAudioRetaining: AnyObject {
  /// 録音を始めた
  func begin(_ session: SessionID)
  /// 録音のチャンクが届いた。音声認識へ渡す前に呼ぶ
  func append(_ chunk: AudioChunk, to session: SessionID)
  /// 録音のチャンクをすべて渡し終えた（録音が止まった）。セッションごとに1回だけ、`end` より前に呼ぶ
  func finishRecording(_ session: SessionID)
  /// 認識をやり直すための、メモリ上の録音音声。音声がない、または `end` を伝えた後なら `nil`
  func recordedAudio(for session: SessionID) -> RecordedAudio?
  /// `begin` を伝えたセッションが終わった。セッションごとに1回だけ呼ぶ。`completed` は挿入（またはプレビューへの退避）まで終えたとき `true`、
  /// キャンセル・失敗で終えたとき `false`
  func end(_ session: SessionID, completed: Bool)
}

/// 失敗した認識を、メモリ上の録音音声でやり直すかの判断（7章, AC-10）。
///
/// 本番は `STTWorkerRecognitionRecovery`（STT Worker の異常終了で失敗にしたセッションで、再起動の回数制限の範囲内のときだけ）。
protocol SessionRecognitionRecovering: Sendable {
  /// 認識が `error` で失敗した `session` を、録音音声で認識し直すか。受け手が失敗を受け取った後に呼ぶ
  func shouldRecognizeAgain(_ session: SessionID, after error: SpeechRecognitionError) async -> Bool
}
