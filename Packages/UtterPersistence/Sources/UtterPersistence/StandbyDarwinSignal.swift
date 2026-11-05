import Foundation
import UtterCore

/// 待機セッションのプロセス間の「読み直して」の通知（Darwin 通知, iOS-04）。
///
/// 中身は運ばない。正は App Group のファイルで、通知は読み直しのきっかけにだけ使う。
/// 欠落・重複・遅延を前提にし、受けた側は定期的な読み直しも続ける。
public enum StandbyDarwinSignal: Hashable, Sendable {
  /// キーボードが合図（または生存の印）のファイルを書いた
  case command
  /// 本体アプリが状態のファイルを書いた
  case hostState

  /// 通知の名前。App Group ごとに分ける
  func name(groupIdentifier: String) -> String {
    switch self {
    case .command: "\(groupIdentifier).standby.command"
    case .hostState: "\(groupIdentifier).standby.host"
    }
  }

  public func post(groupIdentifier: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(name(groupIdentifier: groupIdentifier) as CFString), nil, nil, true)
  }

  /// 通知を受けたら `handler` をメインキューで呼ぶ。返した値を保持している間だけ受ける
  public func observe(
    groupIdentifier: String, handler: @escaping @Sendable () -> Void
  ) -> StandbyDarwinObservation {
    StandbyDarwinObservation(name: name(groupIdentifier: groupIdentifier), handler: handler)
  }
}

/// `StandbyDarwinSignal.observe` の受信。解放すると受信をやめる。
public final class StandbyDarwinObservation: Sendable {
  private let name: String
  private let handler: @Sendable () -> Void

  init(name: String, handler: @escaping @Sendable () -> Void) {
    self.name = name
    self.handler = handler
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let observation = Unmanaged<StandbyDarwinObservation>.fromOpaque(observer)
          .takeUnretainedValue()
        let handler = observation.handler
        DispatchQueue.main.async { handler() }
      },
      name as CFString, nil, .deliverImmediately)
  }

  deinit {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(name as CFString), nil)
  }
}

/// キーボードの合図・生存の印の書き込みの後に、本体アプリへ通知を送る（`KeyboardStandbySignals`）。
public struct NotifyingKeyboardStandbySignals: KeyboardStandbySignals {
  private let store: StandbySessionStore
  private let groupIdentifier: String

  public init(store: StandbySessionStore, groupIdentifier: String) {
    self.store = store
    self.groupIdentifier = groupIdentifier
  }

  public func issueCommand(
    _ action: StandbyCommand.Action, sessionID: SessionID, at now: Date
  ) async throws -> StandbyCommand {
    let command = try await store.issueCommand(action, sessionID: sessionID, at: now)
    StandbyDarwinSignal.command.post(groupIdentifier: groupIdentifier)
    return command
  }

  public func saveHeartbeat(_ heartbeat: KeyboardHeartbeat) async throws {
    // 生存の印は定期的に読み直されるため、通知は送らない
    try await store.saveHeartbeat(heartbeat)
  }

  public func loadHostState() async throws -> StandbyHostState? {
    try await store.loadHostState()
  }
}
