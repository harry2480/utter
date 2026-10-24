import OSLog

/// 計測区間を Signpost として発行する。
///
/// カテゴリは Points of Interest にするため、Instruments の Points of Interest / os_signpost で区間として見える。
/// 区間には名前だけを付け、メッセージ（発話本文・ファイル名・アプリ名など）は一切載せない。
public struct PerfSignposts: Sendable {
  /// Signpost のサブシステム。集計スクリプトはこの値で絞り込む。
  public static let defaultSubsystem = "utter.perf"

  public let subsystem: String
  private let signposter: OSSignposter

  public init(subsystem: String = PerfSignposts.defaultSubsystem) {
    self.subsystem = subsystem
    signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
  }

  /// 区間を開始する。返した値を `end(_:)` に渡して終了する。
  /// 同じ区間名が重なっても取り違えないよう、開始ごとに別の Signpost ID を使う。
  public func begin(_ interval: PerfInterval) -> PerfIntervalHandle {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval(interval.signpostName, id: id)
    return PerfIntervalHandle(interval: interval, state: state)
  }

  /// 区間を終了する。
  public func end(_ handle: PerfIntervalHandle) {
    signposter.endInterval(handle.interval.signpostName, handle.state)
  }

  /// `body` の実行時間を区間として記録する。
  public func measure<T>(
    _ interval: PerfInterval,
    _ body: () async throws -> T
  ) async rethrows -> T {
    let handle = begin(interval)
    defer { end(handle) }
    return try await body()
  }
}

/// 開始済みの区間。`PerfSignposts.end(_:)` に渡す。
public struct PerfIntervalHandle: Sendable {
  public let interval: PerfInterval
  let state: OSSignpostIntervalState
}
