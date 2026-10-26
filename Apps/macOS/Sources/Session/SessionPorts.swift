import UtterAI
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
  /// 今の入力先の機密入力の判定に使う状態（7章, AC-12）。クラウド送信・履歴保存の直前に呼ぶ。
  ///
  /// フォーカス中の入力対象が録音開始時と違う・取れない場合は、入力欄の属性とアプリを判定できない（`unknown` / `nil`）として返す
  func sensitiveInputContext(for target: RecordedInsertionTarget) -> SensitiveInputContext
}

/// 認識したテキストの整形（TXT-01, TXT-03, AI-01, AI-03, AC-06, AC-12, CTX-01〜03）。
///
/// 本番は設定に従ってローカル整形とクラウド整形を選ぶ `SessionRefinementPipeline`。
@MainActor
protocol SessionRefining: AnyObject {
  /// 整形する。発話を失わないよう失敗しない（クラウド整形できなければローカル整形の結果を返す）。
  ///
  /// - Parameters:
  ///   - transcript: 認識したテキスト
  ///   - frontmostApp: 録音開始時の前面アプリの bundle ID。スタイル区分の判定にだけ使い、送信しない（CTX-03）
  ///   - sensitivity: 今の入力先の状態。クラウドへ送る直前に呼ぶ
  /// - Throws: 呼び出し元の Task がキャンセルされた場合
  func refine(
    _ transcript: String,
    frontmostApp: String?,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext
  ) async throws(CancellationError) -> SessionRefinementResult
}

/// 整形の経路を知らせる差し込み口（4.1節, AC-16）。
///
/// 退避の HUD 通知は `SessionCoordinator` が `HUDController` に直接出すため、本番では渡さない（`nil`）。テストで経路を確かめるのに使う。
@MainActor
protocol SessionRefinementReporting: AnyObject {
  /// セッションの整形が終わった。挿入の前に、整形したセッションごとに1回呼ぶ。本文は渡さない
  func refinementFinished(_ route: SessionRefinementRoute, session: SessionID)
}

/// 挿入した本文の入力履歴への保存（7章, AC-12）。
@MainActor
protocol SessionHistoryRecording: AnyObject {
  /// 挿入を終えた本文を保存する。履歴が無効・機密入力なら保存しない。失敗してもセッションには影響させない
  ///
  /// - Parameter sensitivity: 保存の直前の入力先の状態
  func record(
    _ text: String, session: SessionID,
    sensitivity: @escaping @MainActor () -> SensitiveInputContext) async
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
