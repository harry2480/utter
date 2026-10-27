/// 計測区間の開始・終了を順に記録するだけの計測器（#52）。Signpost は出さない。
@MainActor
final class RecordingPerfIntervals: PerfIntervalMeasuring {
  enum Event: Hashable {
    case begin(PerfInterval)
    case end(PerfInterval)
  }

  private(set) var events: [Event] = []
  /// 同じ値で2回以上 `end` された回数（契約違反）
  private(set) var duplicateEnds = 0
  private var openTokens: [PerfIntervalToken] = []
  private var nextID: UInt64 = 0

  /// 開始して、まだ終えていない区間（開始順）
  var openIntervals: [PerfInterval] {
    openTokens.map(\.interval)
  }

  /// 終えた区間（終えた順）
  var ended: [PerfInterval] {
    events.compactMap {
      if case .end(let interval) = $0 { return interval }
      return nil
    }
  }

  /// 始めた区間（始めた順）
  var begun: [PerfInterval] {
    events.compactMap {
      if case .begin(let interval) = $0 { return interval }
      return nil
    }
  }

  func begin(_ interval: PerfInterval) -> PerfIntervalToken {
    let token = PerfIntervalToken(interval: interval, id: nextID)
    nextID += 1
    openTokens.append(token)
    events.append(.begin(interval))
    return token
  }

  func end(_ token: PerfIntervalToken) {
    guard let index = openTokens.firstIndex(of: token) else {
      duplicateEnds += 1
      return
    }
    openTokens.remove(at: index)
    events.append(.end(token.interval))
  }
}
