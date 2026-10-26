import Foundation
import UtterPersistence

/// 共有結果の保存先（iOS-IPC-01, iOS-07）。
///
/// App Group を使えるかは Phase i0（#56）の判定待ちのため、`Config/Local.xcconfig` で App Group ID を設定し、
/// そのコンテナを開けたときだけ App Group に保存してキーボード拡張と共有する。
/// それ以外はアプリ内の保存先だけを使い、キーボードとは共有しない（救済画面での確認・コピーはできる）。
public struct SharedResultStorage: Sendable {
  public let store: SharedResultStore
  public let sharing: SharedResultSharing

  public init(store: SharedResultStore, sharing: SharedResultSharing) {
    self.store = store
    self.sharing = sharing
  }

  /// 設定に応じて保存先を選ぶ。
  /// - Parameters:
  ///   - appGroupIdentifier: Info.plist に埋め込んだ App Group ID。未設定なら空か `nil`。前後の空白は無視する
  ///   - appLocalDirectory: App Group を使わないときの保存先（アプリのコンテナ内）
  ///   - makeAppGroupStore: App Group のコンテナを開く。既定は `SharedResultStore(groupIdentifier:)`。
  ///     Entitlement がなく開けなければ `nil`
  public static func resolve(
    appGroupIdentifier: String?,
    appLocalDirectory: URL,
    makeAppGroupStore: (String) -> SharedResultStore? = { SharedResultStore(groupIdentifier: $0) }
  ) -> SharedResultStorage {
    let identifier = appGroupIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !identifier.isEmpty else {
      return SharedResultStorage(
        store: SharedResultStore(directory: appLocalDirectory),
        sharing: .appLocalOnly(.appGroupNotConfigured))
    }
    guard let store = makeAppGroupStore(identifier) else {
      // 設定したのに開けない（Entitlement の不足・署名の不備）。共有はせず、結果はアプリ内に残す
      return SharedResultStorage(
        store: SharedResultStore(directory: appLocalDirectory),
        sharing: .appLocalOnly(.appGroupUnavailable))
    }
    return SharedResultStorage(store: store, sharing: .appGroup)
  }
}

/// 共有結果をキーボード拡張と共有するか。
public enum SharedResultSharing: Hashable, Sendable {
  /// App Group に保存し、キーボード拡張と共有する
  case appGroup
  /// アプリ内にだけ保存する。キーボードからは挿入できない
  case appLocalOnly(AppLocalReason)

  public enum AppLocalReason: Hashable, Sendable {
    /// App Group ID を設定していない（既定）
    case appGroupNotConfigured
    /// App Group ID を設定したが、コンテナを開けなかった
    case appGroupUnavailable
  }
}
