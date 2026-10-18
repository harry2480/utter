import PerfProbe

/// 要件定義6章のストレッチ目標（ミリ秒）。保証値ではない。
/// 6章の数値を再設定したら、ここも合わせて直す。
public struct PerfTarget: Hashable, Sendable {
  public let p50: Double?
  public let p95: Double?

  /// 6章に目標がある区間だけを返す。内訳の区間（STT確定・LLM・挿入・モデルロード）は目標なし。
  public static func chapter6(for interval: PerfInterval) -> PerfTarget? {
    switch interval {
    case .recordingStart: PerfTarget(p50: nil, p95: 200)
    case .realtimeFirstText: PerfTarget(p50: nil, p95: 1_500)
    case .stopToInsertLocal: PerfTarget(p50: 300, p95: 700)
    case .stopToInsertAI: PerfTarget(p50: 800, p95: 1_500)
    case .sttFinalize, .llmFirstToken, .llmComplete, .insert, .modelLoad: nil
    }
  }

  /// 目標の表記（例: `p50≤300 / p95≤700`）
  public var label: String {
    [p50.map { "p50≤\(Self.format($0))" }, p95.map { "p95≤\(Self.format($0))" }]
      .compactMap(\.self)
      .joined(separator: " / ")
  }

  /// 集計値が目標の範囲内か。判定は機械的な比較だけで、計測条件が6章どおりかは人が確認する。
  public func isMet(by statistics: IntervalStatistics) -> Bool {
    (p50.map { statistics.p50 <= $0 } ?? true) && (p95.map { statistics.p95 <= $0 } ?? true)
  }

  static func format(_ milliseconds: Double) -> String {
    milliseconds.rounded() == milliseconds ? String(Int(milliseconds)) : String(milliseconds)
  }
}
