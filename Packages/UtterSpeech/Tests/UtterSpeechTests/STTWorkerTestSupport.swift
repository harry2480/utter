import Synchronization

@testable import UtterSpeech

/// 呼ばれた待ち時間を記録し、`resumeAll()` まで戻らない `sleep`。実時間を待たずに保持時間の経過を再現する
final class ManualSleeper: Sendable {
  private struct State {
    var durations: [Duration] = []
    var waiters: [CheckedContinuation<Void, any Error>] = []
  }

  private let state = Mutex(State())

  var durations: [Duration] {
    state.withLock { $0.durations }
  }

  var waiterCount: Int {
    state.withLock { $0.waiters.count }
  }

  func sleep(_ duration: Duration) async throws {
    try await withCheckedThrowingContinuation { continuation in
      state.withLock {
        $0.durations.append(duration)
        $0.waiters.append(continuation)
      }
    }
  }

  /// 待っている `sleep` をすべて戻す
  func resumeAll() {
    let waiters = state.withLock { state in
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters {
      waiter.resume()
    }
  }
}

/// 条件が成り立つまで他のタスクに譲って待つ。成り立たないまま上限に達したら `false`
func eventually(
  _ condition: @Sendable () async -> Bool, iterations: Int = 10_000
) async -> Bool {
  for _ in 0..<iterations {
    if await condition() {
      return true
    }
    await Task.yield()
  }
  return await condition()
}
