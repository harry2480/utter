/// 要件定義6章の計測区間（#52）。アプリが Signpost で出す区間名はここだけで定義する。
///
/// 文字列は `Verification/PerfProbe/Sources/PerfProbe/PerfInterval.swift`（計測道具の集計が使う区間名）と完全に一致させる。
/// アプリは使い捨ての PerfProbe パッケージに依存しないため、同じ名前をここに持ち、一致は `UtterMacTests` で確かめる。
/// 名前を変えると過去の計測結果と比べられなくなるため、変える場合は PerfProbe と手順書（docs/Phase0検証-性能目標.md）も直す。
/// どこで開始・終了するかは手順書の「アプリでの計測」を参照
enum PerfInterval: String, CaseIterable, Sendable {
  /// 録音開始の操作 → 最初の音声チャンクの受信。6章「録音開始遅延」
  case recordingStart = "RecordingStart"
  /// 録音開始の操作 → Realtime Preview の初回文字表示。6章「Realtime初回文字表示」
  case realtimeFirstText = "RealtimeFirstText"
  /// 録音停止 → STT の確定結果
  case sttFinalize = "STTFinalize"
  /// LLM への要求送信 → 初回トークン。整形の応答をストリームで受け取らないため、今は出さない
  case llmFirstToken = "LLMFirstToken"
  /// LLM への要求送信 → 応答完了
  case llmComplete = "LLMComplete"
  /// 挿入開始 → 挿入完了
  case insert = "Insert"
  /// 録音停止 → 挿入完了（ローカル高速入力、AI整形なし）。6章「ローカル高速入力：停止→挿入」
  case stopToInsertLocal = "StopToInsertLocal"
  /// 録音停止 → 挿入完了（AI整形あり）。6章「AI整形あり：停止→挿入」
  case stopToInsertAI = "StopToInsertAI"
  /// STT モデルのロード開始 → 完了。SpeechAnalyzer はモデルを OS が管理するため、今は出さない
  case modelLoad = "ModelLoad"

  /// Signpost に渡す区間名。`OSSignposter` は `StaticString` しか受け取らないため、文字列リテラルで返す
  var signpostName: StaticString {
    switch self {
    case .recordingStart: "RecordingStart"
    case .realtimeFirstText: "RealtimeFirstText"
    case .sttFinalize: "STTFinalize"
    case .llmFirstToken: "LLMFirstToken"
    case .llmComplete: "LLMComplete"
    case .insert: "Insert"
    case .stopToInsertLocal: "StopToInsertLocal"
    case .stopToInsertAI: "StopToInsertAI"
    case .modelLoad: "ModelLoad"
    }
  }
}

/// 開始した区間。`PerfIntervalMeasuring.end(_:)` に渡して終える。中身は区間名と通し番号だけ
struct PerfIntervalToken: Hashable, Sendable {
  let interval: PerfInterval
  let id: UInt64
}

/// 性能計測の区間を記録する口（6章, #52）。本番は `SignpostPerfIntervals`（Signpost を OS のログへ出すだけ）、
/// テストは記録するだけの Stub。
///
/// 区間には名前だけを付け、発話本文・アプリ名・bundle ID・ファイル名などは渡さない（渡す口を持たない）。送信もしない。
/// 同じ区間名が重なっても取り違えないよう、開始ごとに別の値を返す
@MainActor
protocol PerfIntervalMeasuring: AnyObject, Sendable {
  /// 区間を始める
  func begin(_ interval: PerfInterval) -> PerfIntervalToken
  /// `begin(_:)` で始めた区間を終える。同じ値で2回呼ばない
  func end(_ token: PerfIntervalToken)
}
