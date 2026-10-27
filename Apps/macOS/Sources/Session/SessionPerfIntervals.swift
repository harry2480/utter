/// 進行中のセッションの性能計測の区間（6章, #52）。`SessionCoordinator` だけが使う。
///
/// 開いている区間を区間名ごとに1つだけ覚える。セッションは同時に1つしか進まないため、セッション ID は持たず、
/// 古いセッションの非同期処理からの呼び出しは呼び出し側が `isActive` で捨てる。
/// 終点に達しないままセッションが終わったら（キャンセル・失敗・録音の抑止・別経路）、`endAll()` でその時点で閉じ、
/// 開いたままの区間を残さない。計測器がなければ（`nil`）何もしない
@MainActor
final class SessionPerfIntervals {
  private let measurer: (any PerfIntervalMeasuring)?
  private var open: [PerfInterval: PerfIntervalToken] = [:]

  init(measurer: (any PerfIntervalMeasuring)?) {
    self.measurer = measurer
  }

  /// 区間を始める。同じ区間が開いていれば何もしない
  func begin(_ interval: PerfInterval) {
    guard let measurer, open[interval] == nil else { return }
    open[interval] = measurer.begin(interval)
  }

  /// 区間を終える。開いていなければ何もしない
  func end(_ interval: PerfInterval) {
    guard let token = open.removeValue(forKey: interval) else { return }
    measurer?.end(token)
  }

  /// 開いている区間をすべて終える（`PerfInterval` の宣言順）
  func endAll() {
    for interval in PerfInterval.allCases {
      end(interval)
    }
  }
}
