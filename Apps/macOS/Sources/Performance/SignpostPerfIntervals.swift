import OSLog

/// 計測区間を Signpost として OS のログへ出す（6章, #52）。
///
/// サブシステム `utter.perf`、カテゴリ Points of Interest で出すため、
/// `Verification/PerfProbe/scripts/record-signposts.sh`（xctrace の os_signpost）と Instruments の
/// Points of Interest で区間として見える。
/// 区間には名前だけを付け、メッセージ（発話本文・アプリ名・bundle ID・ファイル名など）は一切載せない。送信もしない。
///
/// ビルド構成や起動引数によらず常に出す。Points of Interest は Instruments などが記録している間だけ有効になるカテゴリで、
/// 記録していなければ Signpost は有効かを確かめるだけで戻る（ほぼ無コスト）。Release ビルドのまま計測できるようにするため
@MainActor
final class SignpostPerfIntervals: PerfIntervalMeasuring {
  /// Signpost のサブシステム。PerfProbe の `PerfSignposts.defaultSubsystem` と同じ値にする
  nonisolated static let subsystem = "utter.perf"

  private let signposter = OSSignposter(
    subsystem: SignpostPerfIntervals.subsystem, category: .pointsOfInterest)
  /// 開始して、まだ終えていない区間
  private var states: [UInt64: OSSignpostIntervalState] = [:]
  private var nextID: UInt64 = 0

  func begin(_ interval: PerfInterval) -> PerfIntervalToken {
    let id = nextID
    nextID &+= 1
    states[id] = signposter.beginInterval(interval.signpostName, id: signposter.makeSignpostID())
    return PerfIntervalToken(interval: interval, id: id)
  }

  func end(_ token: PerfIntervalToken) {
    guard let state = states.removeValue(forKey: token.id) else { return }
    signposter.endInterval(token.interval.signpostName, state)
  }
}
