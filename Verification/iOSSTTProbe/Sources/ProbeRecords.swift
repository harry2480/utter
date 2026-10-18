import Foundation

/// `Packages/UtterEvaluation` の `EvaluationSample` と同じキー・型を持つ JSON 表現。
/// 書き出した配列は `utter-eval` がそのまま読める（docs/精度評価.md の「結果の JSON」）。
/// 検証用アプリは UtterEvaluation（macOS のみ）にリンクしないため、形だけを合わせる。
struct EvaluationRecord: Codable, Hashable, Identifiable, Sendable {
  var id: String
  /// `EvaluationCategoryOption` の rawValue
  var category: String
  /// 発話どおりの正解。空のままでは `utter-eval` が読めないため、書き出しから除く
  var reference: String
  var terms: [String]?
  var sttOutput: String?
  /// 取り込んだ評価セットにあれば保持する（このアプリでは作らない）
  var refinedOutput: String?
  var meaningChanges: [String]?
}

/// 評価セットの区分（docs/精度評価.md）。
enum EvaluationCategoryOption: String, CaseIterable, Identifiable, Sendable {
  case japanese
  case mixedJapaneseEnglish
  case developerTerms
  case numbers
  case selfCorrection
  case noisy

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .japanese: "日本語"
    case .mixedJapaneseEnglish: "日英混在"
    case .developerTerms: "開発用語"
    case .numbers: "数字"
    case .selfCorrection: "自己訂正"
    case .noisy: "騒音"
    }
  }
}

extension EvaluationRecord {
  /// `utter-eval` の入力検証（EvaluationSampleError）に当たる不備。発話本文は含めない。
  var exportProblem: String? {
    if EvaluationCategoryOption(rawValue: category) == nil {
      return "区分が不正"
    }
    if reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "正解が未入力"
    }
    if let terms, terms.contains(where: { !reference.contains($0) }) {
      return "用語が正解に含まれていない"
    }
    if meaningChanges != nil, refinedOutput == nil {
      return "整形結果がないのに意味改変を判定している"
    }
    return nil
  }
}

/// 1回の認識の計測値。発話本文は含めないため、`docs/計測/` への転記に使える。
struct RunMetrics: Codable, Identifiable, Sendable {
  var id: Int
  var sampleID: String
  /// `microphone` または `file`
  var source: String
  var engine: String
  var progressiveResults: Bool
  var modelRetention: String
  var locale: String
  var startedAt: Date
  var speechAuthorization: String

  /// マイク: 入力開始から停止まで。ファイル: ファイルの長さ
  var audioDurationSeconds: Double?
  /// AVAudioSession の有効化（マイクのみ）
  var sessionActivationMilliseconds: Double?
  /// SpeechAnalyzer.prepareToAnalyze（モデルのロードを含む）
  var analyzerPrepareMilliseconds: Double?
  /// 録音ボタンを押してからマイク入力が始まるまで（録音開始遅延。許可ダイアログの時間は除く。モデル準備を含む）
  var startToInputMilliseconds: Double?
  /// 入力開始から最初の暫定結果まで
  var firstVolatileResultMilliseconds: Double?
  /// 入力開始から最初の確定結果まで
  var firstFinalResultMilliseconds: Double?
  /// 停止ボタンから最終確定（解析終了）まで（マイクのみ）
  var stopToFinishMilliseconds: Double?
  /// 入力開始から解析終了まで（ファイルのみ）
  var processingMilliseconds: Double?
  /// 処理時間 ÷ 音声の長さ（ファイルのみ。1 未満なら実時間より速い）
  var realTimeFactor: Double?
  var volatileResultCount: Int = 0
  var finalResultCount: Int = 0
  /// 最終テキストの文字数（本文は含めない）
  var outputCharacterCount: Int = 0

  /// phys_footprint（task_vm_info）。Xcode の Memory ゲージ・jetsam 判定と同じ指標
  var footprintBeforeMB: Double?
  /// 実行中のサンプリング（0.5秒間隔）での最大値
  var footprintPeakSampledMB: Double?
  var footprintAfterMB: Double?
  /// 終了 5 秒後（処理後の負荷復帰の目安, 6章）
  var footprintAfter5sMB: Double?
  /// プロセス起動以降の phys_footprint の最大値（ledger_phys_footprint_peak）。サンプル間の瞬間的な山も含む
  var processPeakFootprintMB: Double?
  /// os_proc_available_memory の最小値（jetsam 上限までの残り）
  var minAvailableMemoryMB: Double?
  var thermalStateStart: String?
  var thermalStateMax: String?
  var thermalStateEnd: String?
  var batteryLevelStart: Float?
  var batteryLevelEnd: Float?
  var lowPowerModeStart: Bool?
  /// 電話着信などのオーディオ割り込みで止まった
  var interrupted: Bool = false
  /// エラーの種類（発話本文は含まない）
  var error: String?
}

/// 書き出しの先頭に付ける端末情報。端末を一意に特定する識別子は含めない。
struct DeviceSummary: Codable, Sendable {
  /// 機種の識別子（例: iPhone17,1）。個体の識別子ではない
  var modelIdentifier: String
  var systemVersion: String
  var physicalMemoryMB: Double
  var exportedAt: Date
}

struct MetricsExport: Codable, Sendable {
  var device: DeviceSummary
  var runs: [RunMetrics]
}

/// 実行中の資源のサンプル。タイムライン CSV の1行。
struct ResourceSample: Sendable {
  var uptimeSeconds: Double
  var date: Date
  var footprintBytes: UInt64?
  var processPeakFootprintBytes: UInt64?
  var availableBytes: UInt64
  var thermalState: ProcessInfo.ThermalState
  var batteryLevel: Float
  var lowPowerMode: Bool
  var activeRunID: Int?
}

extension ProcessInfo.ThermalState {
  var label: String {
    switch self {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}

func megabytes(_ bytes: UInt64?) -> Double? {
  bytes.map { Double($0) / 1_048_576 }
}

func milliseconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
}
