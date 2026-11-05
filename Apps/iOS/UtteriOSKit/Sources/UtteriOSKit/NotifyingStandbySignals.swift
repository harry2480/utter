import Foundation
import UtterPersistence

/// 本体アプリの状態を書いたあとに、キーボードへ「読み直して」の通知を送る（iOS-04）。
/// 合図と生存の印は読むだけで、通知は送らない。
public struct NotifyingStandbySignals: StandbySessionSignals {
  private let store: StandbySessionStore
  private let groupIdentifier: String

  public init(store: StandbySessionStore, groupIdentifier: String) {
    self.store = store
    self.groupIdentifier = groupIdentifier
  }

  public func loadCommand() async throws -> StandbyCommand? {
    try await store.loadCommand()
  }

  public func loadHeartbeat() async throws -> KeyboardHeartbeat? {
    try await store.loadHeartbeat()
  }

  public func saveHostState(_ state: StandbyHostState) async throws {
    try await store.saveHostState(state)
    StandbyDarwinSignal.hostState.post(groupIdentifier: groupIdentifier)
  }
}
