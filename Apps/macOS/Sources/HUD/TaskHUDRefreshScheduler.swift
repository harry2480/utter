import UtterCore

/// `ContinuousClock` で待って HUD の表示を更新する（REC-03）。
@MainActor
final class TaskHUDRefreshScheduler: HUDRefreshScheduling {
  private var task: Task<Void, Never>?

  func schedule(at deadline: ContinuousClock.Instant?, _ action: @escaping @MainActor () -> Void) {
    task?.cancel()
    task = nil
    guard let deadline else { return }
    task = Task { @MainActor in
      do {
        try await Task.sleep(until: deadline, clock: .continuous)
      } catch {
        return  // 取り消された
      }
      action()
    }
  }
}
