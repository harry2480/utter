/// 1つの区間名についての集計値（ミリ秒）。
public struct IntervalStatistics: Hashable, Sendable {
  public let name: String
  public let count: Int
  public let min: Double
  public let p50: Double
  public let p95: Double
  public let max: Double
  public let mean: Double

  /// - Returns: 値が空なら `nil`
  public init?(name: String, milliseconds values: [Double]) {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    self.name = name
    count = sorted.count
    min = sorted[0]
    max = sorted[sorted.count - 1]
    p50 = Self.nearestRank(50, in: sorted)
    p95 = Self.nearestRank(95, in: sorted)
    mean = sorted.reduce(0, +) / Double(sorted.count)
  }

  /// 最近傍順位法のパーセンタイル。補間しないため、必ず実測値のどれかになる。
  /// 件数が少ないと p95 は最大値と同じになる（20件未満では p95 = max）。
  static func nearestRank(_ percentile: Double, in sorted: [Double]) -> Double {
    let rank = Int((percentile / 100 * Double(sorted.count)).rounded(.up))
    return sorted[Swift.max(rank, 1) - 1]
  }

  /// 記録を区間名ごとにまとめて集計する。区間名の昇順で返す。
  public static func summarize(_ records: [SignpostIntervalRecord]) -> [IntervalStatistics] {
    Dictionary(grouping: records, by: \.name)
      .compactMap { name, group in
        IntervalStatistics(name: name, milliseconds: group.map(\.durationMilliseconds))
      }
      .sorted { $0.name < $1.name }
  }
}
