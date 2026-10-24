/// 要件定義6章の計測区間。Signpost の区間名はここだけで定義する。
///
/// 区間名は `docs/Phase0検証-性能目標.md` の「Signpost 区間名」の表と一致させる。
/// 名前を変えると過去の計測結果と比較できなくなるため、変更する場合は手順書も同時に直す。
public enum PerfInterval: String, CaseIterable, Sendable {
  /// 録音開始の操作（ショートカット押下）→ 最初の音声バッファ受信。6章「録音開始遅延」
  case recordingStart = "RecordingStart"
  /// 録音開始の操作 → Realtime Preview の初回文字表示。6章「Realtime初回文字表示」
  case realtimeFirstText = "RealtimeFirstText"
  /// 録音停止 → STT の確定結果を受け取るまで
  case sttFinalize = "STTFinalize"
  /// LLM への要求送信 → 初回トークン受信
  case llmFirstToken = "LLMFirstToken"
  /// LLM への要求送信 → 応答完了
  case llmComplete = "LLMComplete"
  /// 挿入開始 → 挿入完了（成功確認まで）
  case insert = "Insert"
  /// 録音停止 → 挿入完了（ローカル高速入力、AI整形なし）。6章「ローカル高速入力：停止→挿入」
  case stopToInsertLocal = "StopToInsertLocal"
  /// 録音停止 → 挿入完了（AI整形あり）。6章「AI整形あり：停止→挿入」
  case stopToInsertAI = "StopToInsertAI"
  /// STT モデルのロード開始 → ロード完了。コールドスタートの内訳
  case modelLoad = "ModelLoad"

  /// Signpost に渡す区間名。`OSSignposter` は `StaticString` しか受け取らないため、文字列リテラルで返す。
  public var signpostName: StaticString {
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
