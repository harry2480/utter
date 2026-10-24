import Foundation
import UtterPersistence

/// アプリが使う SQLite データベース（辞書・使用量・任意の入力履歴, 3章, 7章）を1つだけ開いて共有する。
///
/// 起動時には開かず、最初に使う画面が求めたときにメインスレッド以外で開く。開けなかったときは次に求められたときに開き直す。
/// 保存先は利用者のライブラリの Application Support（`<Bundle ID>/utter.sqlite`）。
@MainActor
final class AppDatabaseProvider {
  private var opening: Task<UtterDatabase, any Error>?

  func database() async throws -> UtterDatabase {
    let task: Task<UtterDatabase, any Error>
    if let opening {
      task = opening
    } else {
      task = Task.detached { try UtterDatabase.open(at: try Self.databaseURL()) }
      opening = task
    }
    do {
      return try await task.value
    } catch {
      if opening == task { opening = nil }
      throw error
    }
  }

  private nonisolated static func databaseURL() throws -> URL {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return
      applicationSupport
      .appending(path: Bundle.main.bundleIdentifier ?? "utter", directoryHint: .isDirectory)
      .appending(path: "utter.sqlite", directoryHint: .notDirectory)
  }
}
